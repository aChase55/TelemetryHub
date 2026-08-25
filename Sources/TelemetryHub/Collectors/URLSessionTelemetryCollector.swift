import Foundation
import os

public final class URLSessionTelemetryCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let hub: Telemetry
    private let baseTags: [String: String]
    private let lock = OSAllocatedUnfairLock(initialState: [ObjectIdentifier: TimeInterval]())

    public init(hub: Telemetry = .shared, tags: [String: String] = [:]) {
        self.hub = hub
        self.baseTags = tags
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        let key = ObjectIdentifier(task)
        let duration = metrics.taskInterval.duration
        lock.withLock { $0[key] = duration }
        guard let transaction = metrics.transactionMetrics.last(where: { $0.resourceFetchType == .networkLoad })
            ?? metrics.transactionMetrics.last
        else { return }

        let tags = tags(for: task)
        func histogram(_ suffix: String, from start: Date?, to end: Date?) {
            guard let start, let end else { return }
            hub.histogram("net.http.\(suffix)", end.timeIntervalSince(start) * 1000, unit: .milliseconds, tags: tags)
        }
        histogram("dns", from: transaction.domainLookupStartDate, to: transaction.domainLookupEndDate)
        histogram("connect", from: transaction.connectStartDate, to: transaction.connectEndDate)
        histogram("tls", from: transaction.secureConnectionStartDate, to: transaction.secureConnectionEndDate)
        histogram("ttfb", from: transaction.requestStartDate, to: transaction.responseStartDate)
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        let key = ObjectIdentifier(task)
        let duration = lock.withLock { $0.removeValue(forKey: key) }
        record(task: task, error: error, duration: duration)
    }

    public func recordCompletion(
        of task: URLSessionTask,
        error: (any Error)? = nil
    ) {
        let key = ObjectIdentifier(task)
        let duration = lock.withLock { $0.removeValue(forKey: key) }
        record(task: task, error: error, duration: duration)
    }

    private func record(task: URLSessionTask, error: (any Error)?, duration: TimeInterval?) {
        let tags = tags(for: task)
        let name = traceName(for: task)
        let status: TelemetryTrace.Status
        if let error {
            status = .error(String(describing: error))
        } else if let code = (task.response as? HTTPURLResponse)?.statusCode, code >= 400 {
            status = .error("HTTP \(code)")
        } else {
            status = .ok
        }

        let bytesSent = Double(task.countOfBytesSent)
        let bytesReceived = Double(task.countOfBytesReceived)
        let duration = duration ?? 0
        let uploadBitrate = duration > 0 ? bytesSent * 8 / duration : nil
        let downloadBitrate = duration > 0 ? bytesReceived * 8 / duration : nil

        var measurements: [String: Double] = [
            "bytes.sent": bytesSent,
            "bytes.received": bytesReceived,
        ]
        measurements["bitrate.upload"] = uploadBitrate
        measurements["bitrate.download"] = downloadBitrate

        hub.record(TelemetryTrace(
            name: name,
            kind: .httpRequest,
            start: Date().addingTimeInterval(-duration),
            duration: duration,
            status: status,
            tags: tags,
            measurements: measurements
        ))
        hub.histogram("net.http.duration", duration * 1000, unit: .milliseconds, tags: tags)
        hub.counter("net.http.count", tags: tags)
        hub.counter("net.http.bytes.sent", by: bytesSent, unit: .bytes, tags: tags)
        hub.counter("net.http.bytes.received", by: bytesReceived, unit: .bytes, tags: tags)
        if let uploadBitrate, bytesSent > 0 {
            hub.gauge("net.http.throughput.upload", uploadBitrate, unit: .bitsPerSecond, tags: tags)
        }
        if let downloadBitrate, bytesReceived > 0 {
            hub.gauge("net.http.throughput.download", downloadBitrate, unit: .bitsPerSecond, tags: tags)
        }
        if case .error(let reason) = status {
            hub.counter("net.http.failure.count", tags: tags)
            hub.event("net.http.failure", message: "\(name): \(reason)", level: .error, tags: tags)
        }
    }

    private func tags(for task: URLSessionTask) -> [String: String] {
        var tags = baseTags
        if let url = task.originalRequest?.url {
            tags["host"] = url.host()
        }
        if let method = task.originalRequest?.httpMethod {
            tags["method"] = method
        }
        if let code = (task.response as? HTTPURLResponse)?.statusCode {
            tags["status_code"] = String(code)
        }
        return tags
    }

    private func traceName(for task: URLSessionTask) -> String {
        let method = task.originalRequest?.httpMethod ?? "GET"
        guard let url = task.originalRequest?.url else { return method }
        let path = url.path().isEmpty ? "/" : url.path()
        return "\(method) \(url.host() ?? "")\(path)"
    }
}
