import GRPCCore
import GRPCInProcessTransport
import TelemetryHub
@testable import TelemetryHubGRPC
import Testing

@Suite("gRPC telemetry")
struct TelemetryClientInterceptorTests {
    @Test("Interceptor records a trace after a unary response is consumed")
    @available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
    func recordsUnaryTrace() async throws {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let inProcess = InProcessTransport()

        try await withGRPCServer(transport: inProcess.server, services: [TestService()]) { _ in
            try await withGRPCClient(
                transport: inProcess.client,
                interceptors: [TelemetryClientInterceptor(hub: hub, tags: ["test": "grpc"])]
            ) { client in
                try await client.unary(
                    request: ClientRequest(message: ()),
                    descriptor: .telemetrySuccess,
                    serializer: EmptySerializer(),
                    deserializer: EmptyDeserializer(),
                    options: .defaults
                ) { response in
                    try response.message
                }
            }
        }
        await hub.flush()

        let trace = exporter.traces.first { $0.name == "telemetry.test/Success" }
        #expect(trace?.kind == .grpcCall)
        #expect(trace?.status == .ok)
        #expect(trace?.tags["grpc_code"] == "ok")
        #expect(trace?.tags["test"] == "grpc")
        #expect(exporter.metrics.contains { $0.name == "net.grpc.duration" })
        #expect(exporter.metrics.contains { $0.name == "net.grpc.count" })
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private struct TestService: RegistrableRPCService {
    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        router.registerHandler(
            forMethod: .telemetrySuccess,
            deserializer: EmptyDeserializer(),
            serializer: EmptySerializer()
        ) { stream, context in
            let response = try await success(
                request: ServerRequest<Void>(stream: stream),
                context: context
            )
            return StreamingServerResponse(single: response)
        }
    }

    private func success(
        request: ServerRequest<Void>,
        context: ServerContext
    ) async throws -> ServerResponse<Void> {
        ServerResponse(message: ())
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private extension MethodDescriptor {
    static let telemetrySuccess = Self(
        fullyQualifiedService: "telemetry.test",
        method: "Success",
        type: .unary
    )
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private struct EmptySerializer: MessageSerializer {
    func serialize<Bytes: GRPCContiguousBytes>(_ message: Void) throws -> Bytes {
        Bytes(repeating: 0, count: 0)
    }
}

@available(iOS 18.0, macOS 15.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
private struct EmptyDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws {}
}
