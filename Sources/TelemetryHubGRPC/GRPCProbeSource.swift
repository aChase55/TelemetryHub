import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2TransportServices
import TelemetryHub
import os

/// Configuration for a real unary gRPC probe.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public struct GRPCProbeConfiguration: Sendable, Hashable {
    /// `nil` keeps the source manual-only.
    public var interval: TimeInterval?
    public var host: String
    public var port: Int
    public var usesTLS: Bool
    public var timeout: Duration
    public var service: String
    public var method: String
    public var tags: [String: String]

    public init(
        interval: TimeInterval? = nil,
        host: String = "grpcb.in",
        port: Int = 9001,
        usesTLS: Bool = true,
        timeout: Duration = .seconds(10),
        service: String = "grpcbin.GRPCBin",
        method: String = "Empty",
        tags: [String: String] = ["provider": "grpcbin"]
    ) {
        self.interval = interval
        self.host = host
        self.port = max(1, min(port, 65_535))
        self.usesTLS = usesTLS
        self.timeout = timeout
        self.service = service
        self.method = method
        self.tags = tags
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public struct GRPCProbeResult: Sendable, Hashable {
    public let timestamp: Date
    public let method: String
    public let duration: TimeInterval
    public let errorDescription: String?

    public var succeeded: Bool { errorDescription == nil }
}

/// Makes a real unary gRPC call and records it through ``TelemetryClientInterceptor``.
///
/// The default target is grpcbin's public `grpcbin.GRPCBin/Empty` endpoint. Configure
/// your own endpoint for production use. Each call produces a `grpcCall` trace plus
/// `net.grpc.duration`, count, status, and failure telemetry.
@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
public final class GRPCProbeSource: TelemetrySource, @unchecked Sendable {
    public let sourceID: String

    private struct State {
        weak var hub: Telemetry?
        var task: Task<Void, Never>?
        var isProbing = false
    }

    private let configuration: GRPCProbeConfiguration
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    public init(
        sourceID: String = "grpc-probe",
        configuration: GRPCProbeConfiguration = GRPCProbeConfiguration()
    ) {
        self.sourceID = sourceID
        self.configuration = configuration
    }

    deinit {
        lock.withLock { $0.task }?.cancel()
    }

    public func start(hub: Telemetry) {
        stop()
        lock.withLock { $0.hub = hub }
        guard let interval = configuration.interval else { return }

        let task = Task(priority: .utility) { [weak self] in
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

    /// Executes one unary gRPC probe. Returns `nil` if stopped or already running.
    @discardableResult
    public func probe() async -> GRPCProbeResult? {
        let hub = lock.withLock { state -> Telemetry? in
            guard !state.isProbing, let hub = state.hub else { return nil }
            state.isProbing = true
            return hub
        }
        guard let hub else { return nil }
        defer { lock.withLock { $0.isProbing = false } }

        let started = ContinuousClock.now
        let descriptor = MethodDescriptor(
            fullyQualifiedService: configuration.service,
            method: configuration.method,
            type: .unary
        )

        do {
            let security: HTTP2ClientTransport.TransportServices.TransportSecurity = configuration.usesTLS ? .tls : .plaintext
            let transport = try HTTP2ClientTransport.TransportServices(
                target: .dns(host: configuration.host, port: configuration.port),
                transportSecurity: security
            )
            var options = CallOptions.defaults
            options.timeout = configuration.timeout

            try await withGRPCClient(
                transport: transport,
                interceptors: [TelemetryClientInterceptor(hub: hub, tags: traceTags)]
            ) { client in
                try await client.unary(
                    request: ClientRequest(message: ()),
                    descriptor: descriptor,
                    serializer: EmptyMessageSerializer(),
                    deserializer: EmptyMessageDeserializer(),
                    options: options
                ) { response in
                    try response.message
                }
            }

            return GRPCProbeResult(
                timestamp: Date(),
                method: descriptor.fullyQualifiedMethod,
                duration: Self.seconds(started.duration(to: .now)),
                errorDescription: nil
            )
        } catch is CancellationError {
            return nil
        } catch {
            return GRPCProbeResult(
                timestamp: Date(),
                method: descriptor.fullyQualifiedMethod,
                duration: Self.seconds(started.duration(to: .now)),
                errorDescription: String(describing: error)
            )
        }
    }

    private var traceTags: [String: String] {
        configuration.tags.merging([
            "host": configuration.host,
            "transport": configuration.usesTLS ? "tls" : "plaintext",
        ]) { current, _ in current }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private struct EmptyMessageSerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Void) throws -> Bytes {
        Bytes(repeating: 0, count: 0)
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private struct EmptyMessageDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws {}
}
