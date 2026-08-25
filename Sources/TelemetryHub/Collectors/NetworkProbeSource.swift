import Foundation
import os

/// Endpoints used by ``NetworkProbeSource`` for active network measurements.
public struct NetworkProbeEndpoints: Sendable, Hashable {
    public var latency: URL
    public var download: URL
    public var upload: URL

    public init(latency: URL, download: URL, upload: URL) {
        self.latency = latency
        self.download = download
        self.upload = upload
    }

    /// Cloudflare's public connection-speed endpoints for a requested download size.
    public static func cloudflare(downloadSize: Int) -> NetworkProbeEndpoints {
        NetworkProbeEndpoints(
            latency: URL(string: "https://speed.cloudflare.com/__down?bytes=0")!,
            download: URL(string: "https://speed.cloudflare.com/__down?bytes=\(max(1, downloadSize))")!,
            upload: URL(string: "https://speed.cloudflare.com/__up")!
        )
    }

    /// Cloudflare's public connection-speed endpoints using a 4 MiB download.
    public static let cloudflare = cloudflare(downloadSize: 4_194_304)
}

public struct NetworkProbeConfiguration: Sendable, Hashable {
    /// `nil` keeps the source manual-only. This avoids unexpected data usage.
    public var interval: TimeInterval?
    public var endpoints: NetworkProbeEndpoints
    public var latencySampleCount: Int
    public var uploadSize: Int
    public var timeout: TimeInterval
    public var rollingWindowSize: Int
    public var tags: [String: String]

    public init(
        interval: TimeInterval? = nil,
        endpoints: NetworkProbeEndpoints = .cloudflare,
        latencySampleCount: Int = 3,
        uploadSize: Int = 1_048_576,
        timeout: TimeInterval = 30,
        rollingWindowSize: Int = 10,
        tags: [String: String] = ["provider": "cloudflare"]
    ) {
        self.interval = interval
        self.endpoints = endpoints
        self.latencySampleCount = max(1, latencySampleCount)
        self.uploadSize = max(1, uploadSize)
        self.timeout = max(1, timeout)
        self.rollingWindowSize = max(1, rollingWindowSize)
        self.tags = tags
    }
}

public struct NetworkProbeResult: Sendable, Hashable {
    public let timestamp: Date
    public let latencyMilliseconds: Double?
    public let jitterMilliseconds: Double?
    public let downloadBitsPerSecond: Double?
    public let uploadBitsPerSecond: Double?
    public let downloadedBytes: Int
    public let uploadedBytes: Int
    public let failures: [String]

    public var succeeded: Bool { failures.isEmpty }
}

/// Actively samples latency and transfer goodput using real HTTP requests.
///
/// Automatic probing is opt-in through `configuration.interval`. Call ``probe()``
/// for user-initiated tests. Prefer endpoints you operate for production use.
public final class NetworkProbeSource: TelemetrySource, @unchecked Sendable {
    public let sourceID: String

    private struct RollingValues: Sendable {
        var values: [Double] = []

        mutating func append(_ value: Double, limit: Int) -> Double {
            values.append(value)
            if values.count > limit {
                values.removeFirst(values.count - limit)
            }
            return values.reduce(0, +) / Double(values.count)
        }
    }

    private struct State {
        weak var hub: Telemetry?
        var task: Task<Void, Never>?
        var isProbing = false
        var latency = RollingValues()
        var download = RollingValues()
        var upload = RollingValues()
    }

    private struct Transfer: Sendable {
        let byteCount: Int
        let duration: TimeInterval

        var bitsPerSecond: Double {
            Double(byteCount) * 8 / max(duration, 0.001)
        }
    }

    private let configuration: NetworkProbeConfiguration
    private let session: URLSession
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    public init(
        sourceID: String = "network-probe",
        configuration: NetworkProbeConfiguration = NetworkProbeConfiguration()
    ) {
        self.sourceID = sourceID
        self.configuration = configuration
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.timeoutIntervalForRequest = configuration.timeout
        sessionConfiguration.timeoutIntervalForResource = configuration.timeout
        sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: sessionConfiguration)
    }

    deinit {
        lock.withLock { $0.task }?.cancel()
        session.invalidateAndCancel()
    }

    public func start(hub: Telemetry) {
        stop()
        lock.withLock { $0.hub = hub }
        guard let interval = configuration.interval else { return }

        let task = Task { [weak self] in
            while !Task.isCancelled {
                _ = await self?.probe()
                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    return
                }
            }
        }
        lock.withLock { $0.task = task }
    }

    public func stop() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            state.hub = nil
            return task
        }
        task?.cancel()
    }

    /// Runs one complete probe. Returns `nil` when the source is stopped or a
    /// previous probe is still running.
    @discardableResult
    public func probe() async -> NetworkProbeResult? {
        let hub = lock.withLock { state -> Telemetry? in
            guard !state.isProbing, let hub = state.hub else { return nil }
            state.isProbing = true
            return hub
        }
        guard let hub else { return nil }
        defer { lock.withLock { $0.isProbing = false } }

        let started = ContinuousClock.now
        var latencySamples: [Double] = []
        var download: Transfer?
        var upload: Transfer?
        var failures: [String] = []

        for _ in 0..<configuration.latencySampleCount {
            do {
                let transfer = try await performRequest(url: cacheBusted(configuration.endpoints.latency))
                let milliseconds = transfer.duration * 1_000
                latencySamples.append(milliseconds)
                hub.histogram("net.probe.latency", milliseconds, unit: .milliseconds, tags: tags(for: configuration.endpoints.latency))
            } catch is CancellationError {
                return nil
            } catch {
                failures.append("latency: \(error.localizedDescription)")
            }
        }

        do {
            download = try await performRequest(url: cacheBusted(configuration.endpoints.download))
        } catch is CancellationError {
            return nil
        } catch {
            failures.append("download: \(error.localizedDescription)")
        }

        do {
            var request = URLRequest(url: cacheBusted(configuration.endpoints.upload))
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            upload = try await performRequest(request, body: Data(repeating: 0xA5, count: configuration.uploadSize))
        } catch is CancellationError {
            return nil
        } catch {
            failures.append("upload: \(error.localizedDescription)")
        }

        let averageLatency = latencySamples.average
        let jitter = latencySamples.meanAbsoluteSuccessiveDifference
        record(
            hub: hub,
            latencySamples: latencySamples,
            averageLatency: averageLatency,
            jitter: jitter,
            download: download,
            upload: upload,
            failures: failures,
            duration: Self.seconds(started.duration(to: .now))
        )

        return NetworkProbeResult(
            timestamp: Date(),
            latencyMilliseconds: averageLatency,
            jitterMilliseconds: jitter,
            downloadBitsPerSecond: download?.bitsPerSecond,
            uploadBitsPerSecond: upload?.bitsPerSecond,
            downloadedBytes: download?.byteCount ?? 0,
            uploadedBytes: upload?.byteCount ?? 0,
            failures: failures
        )
    }

    private func performRequest(url: URL) async throws -> Transfer {
        try await performRequest(URLRequest(url: url), body: nil)
    }

    private func performRequest(_ request: URLRequest, body: Data?) async throws -> Transfer {
        let started = ContinuousClock.now
        let data: Data
        let response: URLResponse
        if let body {
            (data, response) = try await session.upload(for: request, from: body)
        } else {
            (data, response) = try await session.data(for: request)
        }
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse, (200..<400).contains(response.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let duration = Self.seconds(started.duration(to: .now))
        return Transfer(byteCount: body?.count ?? data.count, duration: duration)
    }

    private func record(
        hub: Telemetry,
        latencySamples: [Double],
        averageLatency: Double?,
        jitter: Double?,
        download: Transfer?,
        upload: Transfer?,
        failures: [String],
        duration: TimeInterval
    ) {
        let tags = configuration.tags.merging(["probe": "active"]) { current, _ in current }
        let rolling = lock.withLock { state -> (Double?, Double?, Double?) in
            let latency = averageLatency.map { state.latency.append($0, limit: configuration.rollingWindowSize) }
            let download = download.map { state.download.append($0.bitsPerSecond, limit: configuration.rollingWindowSize) }
            let upload = upload.map { state.upload.append($0.bitsPerSecond, limit: configuration.rollingWindowSize) }
            return (latency, download, upload)
        }

        if let averageLatency {
            hub.gauge("net.probe.latency.average", averageLatency, unit: .milliseconds, tags: tags)
            hub.gauge("net.probe.latency.minimum", latencySamples.min() ?? averageLatency, unit: .milliseconds, tags: tags)
            hub.gauge("net.probe.latency.maximum", latencySamples.max() ?? averageLatency, unit: .milliseconds, tags: tags)
        }
        if let jitter {
            hub.gauge("net.probe.latency.jitter", jitter, unit: .milliseconds, tags: tags)
        }
        if let rollingLatency = rolling.0 {
            hub.gauge("net.probe.latency.rolling_average", rollingLatency, unit: .milliseconds, tags: tags)
        }

        if let download {
            hub.gauge("net.probe.download.bitrate", download.bitsPerSecond, unit: .bitsPerSecond, tags: tags)
            hub.gauge("net.probe.download.duration", download.duration, unit: .seconds, tags: tags)
            hub.counter("net.probe.bytes.received", by: Double(download.byteCount), unit: .bytes, tags: tags)
        }
        if let rollingDownload = rolling.1 {
            hub.gauge("net.probe.download.bitrate.average", rollingDownload, unit: .bitsPerSecond, tags: tags)
        }

        if let upload {
            hub.gauge("net.probe.upload.bitrate", upload.bitsPerSecond, unit: .bitsPerSecond, tags: tags)
            hub.gauge("net.probe.upload.duration", upload.duration, unit: .seconds, tags: tags)
            hub.counter("net.probe.bytes.sent", by: Double(upload.byteCount), unit: .bytes, tags: tags)
        }
        if let rollingUpload = rolling.2 {
            hub.gauge("net.probe.upload.bitrate.average", rollingUpload, unit: .bitsPerSecond, tags: tags)
        }

        hub.histogram("net.probe.duration", duration, unit: .seconds, tags: tags)
        hub.counter("net.probe.count", tags: tags)
        hub.gauge("net.probe.success", failures.isEmpty ? 1 : 0, tags: tags)
        if failures.isEmpty {
            hub.event("net.probe.completed", message: "Active network probe completed", level: .debug, tags: tags)
        } else {
            hub.counter("net.probe.failure.count", tags: tags)
            hub.event("net.probe.failure", message: failures.joined(separator: "; "), level: .warning, tags: tags)
        }
    }

    private func tags(for endpoint: URL) -> [String: String] {
        var tags = configuration.tags
        tags["probe"] = "active"
        tags["host"] = endpoint.host()
        return tags
    }

    private func cacheBusted(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var queryItems = components.queryItems ?? []
        queryItems.append(URLQueryItem(name: "telemetry_probe", value: UUID().uuidString))
        components.queryItems = queryItems
        return components.url ?? url
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

private extension Collection where Element == Double {
    var average: Double? {
        guard !isEmpty else { return nil }
        return reduce(0, +) / Double(count)
    }

    var meanAbsoluteSuccessiveDifference: Double? {
        guard count > 1 else { return nil }
        var previous: Double?
        var total = 0.0
        var differences = 0
        for value in self {
            if let previous {
                total += abs(value - previous)
                differences += 1
            }
            previous = value
        }
        return total / Double(differences)
    }
}
