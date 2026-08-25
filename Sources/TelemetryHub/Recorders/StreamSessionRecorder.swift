import Foundation

public struct StreamStatsSample: Sendable {
    public var bitrateOut: Double?
    public var bitrateIn: Double?
    public var bandwidthEstimate: Double?
    public var bytesSent: Double?
    public var bytesReceived: Double?
    public var packetsSent: Double?
    public var packetsReceived: Double?
    public var packetsLost: Double?
    public var packetLossPercent: Double?
    public var packetsRetransmitted: Double?
    public var packetsDropped: Double?
    public var roundTripTimeMs: Double?
    public var jitterMs: Double?
    public var negotiatedLatencyMs: Double?
    public var framesPerSecond: Double?
    public var frameWidth: Double?
    public var frameHeight: Double?
    public var freezeCount: Double?
    public var audioLevel: Double?
    public var custom: [String: Double]

    public init(
        bitrateOut: Double? = nil,
        bitrateIn: Double? = nil,
        bandwidthEstimate: Double? = nil,
        bytesSent: Double? = nil,
        bytesReceived: Double? = nil,
        packetsSent: Double? = nil,
        packetsReceived: Double? = nil,
        packetsLost: Double? = nil,
        packetLossPercent: Double? = nil,
        packetsRetransmitted: Double? = nil,
        packetsDropped: Double? = nil,
        roundTripTimeMs: Double? = nil,
        jitterMs: Double? = nil,
        negotiatedLatencyMs: Double? = nil,
        framesPerSecond: Double? = nil,
        frameWidth: Double? = nil,
        frameHeight: Double? = nil,
        freezeCount: Double? = nil,
        audioLevel: Double? = nil,
        custom: [String: Double] = [:]
    ) {
        self.bitrateOut = bitrateOut
        self.bitrateIn = bitrateIn
        self.bandwidthEstimate = bandwidthEstimate
        self.bytesSent = bytesSent
        self.bytesReceived = bytesReceived
        self.packetsSent = packetsSent
        self.packetsReceived = packetsReceived
        self.packetsLost = packetsLost
        self.packetLossPercent = packetLossPercent
        self.packetsRetransmitted = packetsRetransmitted
        self.packetsDropped = packetsDropped
        self.roundTripTimeMs = roundTripTimeMs
        self.jitterMs = jitterMs
        self.negotiatedLatencyMs = negotiatedLatencyMs
        self.framesPerSecond = framesPerSecond
        self.frameWidth = frameWidth
        self.frameHeight = frameHeight
        self.freezeCount = freezeCount
        self.audioLevel = audioLevel
        self.custom = custom
    }
}

public enum StreamState: String, Sendable {
    case connecting
    case connected
    case reconnecting
    case disconnected
    case failed
}

public enum StreamTransport: Sendable, Hashable {
    case webRTC
    case srt
    case custom(String)

    public var label: String {
        switch self {
        case .webRTC: "webrtc"
        case .srt: "srt"
        case .custom(let label): label
        }
    }
}

public final class StreamSessionRecorder: Sendable {
    public let streamID: String
    public let transport: StreamTransport
    private let hub: Telemetry
    private let tags: [String: String]

    public init(
        hub: Telemetry = .shared,
        streamID: String,
        transport: StreamTransport,
        tags: [String: String] = [:]
    ) {
        self.hub = hub
        self.streamID = streamID
        self.transport = transport
        var merged = tags
        merged["stream"] = streamID
        merged["transport"] = transport.label
        self.tags = merged
    }

    public func record(_ sample: StreamStatsSample, tags extraTags: [String: String] = [:]) {
        let tags = self.tags.merging(extraTags) { _, new in new }
        func gauge(_ suffix: String, _ value: Double?, _ unit: TelemetryUnit) {
            guard let value else { return }
            hub.gauge("stream.\(suffix)", value, unit: unit, tags: tags)
        }
        gauge("bitrate.out", sample.bitrateOut, .bitsPerSecond)
        gauge("bitrate.in", sample.bitrateIn, .bitsPerSecond)
        gauge("bandwidth.estimate", sample.bandwidthEstimate, .bitsPerSecond)
        gauge("bytes.sent", sample.bytesSent, .bytes)
        gauge("bytes.received", sample.bytesReceived, .bytes)
        gauge("packets.sent", sample.packetsSent, .count)
        gauge("packets.received", sample.packetsReceived, .count)
        gauge("packets.lost", sample.packetsLost, .count)
        gauge("packets.loss", sample.packetLossPercent, .percent)
        gauge("packets.retransmitted", sample.packetsRetransmitted, .count)
        gauge("packets.dropped", sample.packetsDropped, .count)
        gauge("rtt", sample.roundTripTimeMs, .milliseconds)
        gauge("jitter", sample.jitterMs, .milliseconds)
        gauge("latency.negotiated", sample.negotiatedLatencyMs, .milliseconds)
        gauge("fps", sample.framesPerSecond, .framesPerSecond)
        gauge("resolution.width", sample.frameWidth, .pixels)
        gauge("resolution.height", sample.frameHeight, .pixels)
        gauge("freeze.count", sample.freezeCount, .count)
        gauge("audio.level", sample.audioLevel, .none)
        for (name, value) in sample.custom {
            hub.gauge("stream.\(name)", value, tags: tags)
        }
    }

    public func recordState(_ state: StreamState, message: String? = nil) {
        let level: TelemetryEvent.Level = switch state {
        case .failed: .error
        case .reconnecting: .warning
        case .connecting, .connected, .disconnected: .info
        }
        var tags = self.tags
        tags["state"] = state.rawValue
        hub.event("stream.state", message: message ?? state.rawValue, level: level, tags: tags)
        hub.gauge("stream.connected", state == .connected ? 1 : 0, tags: self.tags)
    }
}
