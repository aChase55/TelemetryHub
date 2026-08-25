import Foundation

public struct RequestToken: Sendable {
    public let id: UUID
    public let name: String
    public let start: Date
    let tags: [String: String]

    init(name: String, tags: [String: String]) {
        self.id = UUID()
        self.name = name
        self.start = Date()
        self.tags = tags
    }
}

public final class NetworkRequestRecorder: Sendable {
    public let namePrefix: String
    public let kind: TelemetryTrace.Kind
    private let hub: Telemetry
    private let baseTags: [String: String]

    public init(
        hub: Telemetry = .shared,
        kind: TelemetryTrace.Kind = .httpRequest,
        namePrefix: String? = nil,
        tags: [String: String] = [:]
    ) {
        self.hub = hub
        self.kind = kind
        self.namePrefix = namePrefix ?? Self.defaultPrefix(for: kind)
        self.baseTags = tags
    }

    public func begin(name: String, tags: [String: String] = [:]) -> RequestToken {
        RequestToken(name: name, tags: baseTags.merging(tags) { _, new in new })
    }

    public func end(
        _ token: RequestToken,
        status: TelemetryTrace.Status,
        bytesSent: Int? = nil,
        bytesReceived: Int? = nil,
        tags: [String: String] = [:]
    ) {
        let duration = Date().timeIntervalSince(token.start)
        var allTags = token.tags.merging(tags) { _, new in new }
        allTags["request"] = token.name

        var measurements: [String: Double] = [:]
        if let bytesSent {
            measurements["bytes.sent"] = Double(bytesSent)
            hub.counter("\(namePrefix).bytes.sent", by: Double(bytesSent), unit: .bytes, tags: allTags)
        }
        if let bytesReceived {
            measurements["bytes.received"] = Double(bytesReceived)
            hub.counter("\(namePrefix).bytes.received", by: Double(bytesReceived), unit: .bytes, tags: allTags)
        }

        hub.record(TelemetryTrace(
            name: token.name,
            kind: kind,
            start: token.start,
            duration: duration,
            status: status,
            tags: allTags,
            measurements: measurements
        ))
        hub.histogram("\(namePrefix).duration", duration * 1000, unit: .milliseconds, tags: allTags)
        hub.counter("\(namePrefix).count", tags: allTags)
        if case .error(let reason) = status {
            hub.counter("\(namePrefix).failure.count", tags: allTags)
            hub.event(
                "\(namePrefix).failure",
                message: "\(token.name): \(reason)",
                level: .error,
                tags: allTags
            )
        }
    }

    private static func defaultPrefix(for kind: TelemetryTrace.Kind) -> String {
        switch kind {
        case .httpRequest: "net.http"
        case .grpcCall: "net.grpc"
        case .webSocketSession: "net.ws"
        case .streamSession: "stream"
        case .custom: "net.request"
        }
    }
}
