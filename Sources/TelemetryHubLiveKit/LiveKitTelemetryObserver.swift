import Foundation
import LiveKit
import TelemetryHub
import os

public final class LiveKitTelemetryObserver: NSObject, RoomDelegate, TrackDelegate, @unchecked Sendable {
    private struct State {
        var roomRecorders: [ObjectIdentifier: StreamSessionRecorder] = [:]
        var trackRecorders: [ObjectIdentifier: StreamSessionRecorder] = [:]
    }

    private let hub: Telemetry
    private let baseTags: [String: String]
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    public init(hub: Telemetry = .shared, tags: [String: String] = [:]) {
        self.hub = hub
        self.baseTags = tags
    }

    public func observe(room: Room) {
        room.add(delegate: self)
        _ = roomRecorder(for: room)
    }

    public func stopObserving(room: Room) {
        room.remove(delegate: self)
        lock.withLock { _ = $0.roomRecorders.removeValue(forKey: ObjectIdentifier(room)) }
    }

    public func observe(track: Track) {
        track.add(delegate: self)
        _ = trackRecorder(for: track)
        Task { await track.set(reportStatistics: true) }
    }

    public func stopObserving(track: Track) {
        track.remove(delegate: self)
        lock.withLock { _ = $0.trackRecorders.removeValue(forKey: ObjectIdentifier(track)) }
    }

    public func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        let state: TelemetryHub.StreamState = switch connectionState {
        case .connecting: .connecting
        case .reconnecting: .reconnecting
        case .connected: .connected
        case .disconnected, .disconnecting: .disconnected
        @unknown default: .disconnected
        }
        roomRecorder(for: room).recordState(state)
    }

    public func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        roomRecorder(for: room).recordState(.reconnecting, message: "reconnect mode \(reconnectMode.rawValue)")
    }

    public func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        roomRecorder(for: room).recordState(.connected, message: "reconnected")
    }

    public func room(_ room: Room, didFailToConnectWithError error: LiveKitError?) {
        roomRecorder(for: room).recordState(.failed, message: error.map { String(describing: $0) })
    }

    public func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        if let error {
            roomRecorder(for: room).recordState(.failed, message: String(describing: error))
        } else {
            roomRecorder(for: room).recordState(.disconnected)
        }
    }

    public func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        let score: Double? = switch quality {
        case .lost: 0
        case .poor: 1.0 / 3.0
        case .good: 2.0 / 3.0
        case .excellent: 1
        case .unknown: nil
        @unknown default: nil
        }
        guard let score else { return }
        var tags = baseTags
        tags["transport"] = "webrtc"
        tags["stream"] = roomLabel(for: room)
        tags["participant"] = participant.identity?.stringValue ?? "unknown"
        hub.gauge("stream.quality.score", score, tags: tags)
    }

    public func room(_ room: Room, participant: LocalParticipant, didPublishTrack publication: LocalTrackPublication) {
        if let track = publication.track {
            observe(track: track)
        }
    }

    public func room(_ room: Room, participant: LocalParticipant, didUnpublishTrack publication: LocalTrackPublication) {
        if let track = publication.track {
            stopObserving(track: track)
        }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        if let track = publication.track {
            observe(track: track)
        }
    }

    public func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        if let track = publication.track {
            stopObserving(track: track)
        }
    }

    public func track(_ track: Track, didUpdateStatistics statistics: TrackStatistics, simulcastStatistics: [VideoCodec: TrackStatistics]) {
        let sample = Self.sample(from: statistics)
        var tags: [String: String] = [:]
        tags["kind"] = track.kind == .video ? "video" : "audio"
        tags["direction"] = statistics.outboundRtpStream.isEmpty ? "in" : "out"
        trackRecorder(for: track).record(sample, tags: tags)
    }

    static func sample(from statistics: TrackStatistics) -> StreamStatsSample {
        var sample = StreamStatsSample()

        let inbound = statistics.inboundRtpStream
        if !inbound.isEmpty {
            sample.bitrateIn = Double(inbound.reduce(UInt64(0)) { $0 + $1.bps })
            sample.bytesReceived = sum(inbound.compactMap(\.bytesReceived))
            sample.packetsReceived = sum(inbound.compactMap(\.packetsReceived))
            sample.packetsLost = sum(inbound.compactMap(\.packetsLost).map { max(0, $0) })
            if let jitter = inbound.compactMap(\.jitter).max() {
                sample.jitterMs = jitter * 1000
            }
            sample.framesPerSecond = inbound.compactMap(\.framesPerSecond).max()
            sample.frameWidth = inbound.compactMap(\.frameWidth).max().map(Double.init)
            sample.frameHeight = inbound.compactMap(\.frameHeight).max().map(Double.init)
            if let freezes = inbound.compactMap(\.freezeCount).max() {
                sample.freezeCount = Double(freezes)
            }
            sample.audioLevel = inbound.compactMap(\.audioLevel).max()
        }

        let outbound = statistics.outboundRtpStream
        if !outbound.isEmpty {
            sample.bitrateOut = Double(outbound.reduce(UInt64(0)) { $0 + $1.bps })
            sample.bytesSent = sum(outbound.compactMap(\.bytesSent))
            sample.packetsSent = sum(outbound.compactMap(\.packetsSent))
            sample.packetsRetransmitted = sum(outbound.compactMap(\.retransmittedPacketsSent))
            if sample.framesPerSecond == nil {
                sample.framesPerSecond = outbound.compactMap(\.framesPerSecond).max()
            }
            if sample.frameWidth == nil {
                sample.frameWidth = outbound.compactMap(\.frameWidth).max().map(Double.init)
                sample.frameHeight = outbound.compactMap(\.frameHeight).max().map(Double.init)
            }
        }

        let remoteInbound = statistics.remoteInboundRtpStream
        if !remoteInbound.isEmpty {
            if let rtt = remoteInbound.compactMap(\.roundTripTime).max() {
                sample.roundTripTimeMs = rtt * 1000
            }
            if let fractionLost = remoteInbound.compactMap(\.fractionLost).max() {
                sample.packetLossPercent = fractionLost * 100
            }
            if sample.packetsLost == nil {
                sample.packetsLost = sum(remoteInbound.compactMap(\.packetsLost).map { max(0, $0) })
            }
            if let jitter = remoteInbound.compactMap(\.jitter).max(), sample.jitterMs == nil {
                sample.jitterMs = jitter * 1000
            }
        }

        let selectedPair = statistics.iceCandidatePair.first {
            $0.id == statistics.transportStats?.selectedCandidatePairId
        } ?? statistics.iceCandidatePair.first { $0.nominated == true }
        if let selectedPair {
            if sample.roundTripTimeMs == nil, let rtt = selectedPair.currentRoundTripTime {
                sample.roundTripTimeMs = rtt * 1000
            }
            sample.bandwidthEstimate = selectedPair.availableOutgoingBitrate
        }

        return sample
    }

    private static func sum<Value: BinaryInteger>(_ values: [Value]) -> Double? {
        values.isEmpty ? nil : values.reduce(0.0) { $0 + Double($1) }
    }

    private func roomRecorder(for room: Room) -> StreamSessionRecorder {
        recorder(
            keyedBy: ObjectIdentifier(room),
            in: \.roomRecorders,
            streamID: roomLabel(for: room)
        )
    }

    private func trackRecorder(for track: Track) -> StreamSessionRecorder {
        recorder(
            keyedBy: ObjectIdentifier(track),
            in: \.trackRecorders,
            streamID: track.sid?.stringValue ?? (track.name.isEmpty ? "track" : track.name)
        )
    }

    private func roomLabel(for room: Room) -> String {
        room.name ?? room.sid?.stringValue ?? "room"
    }

    private func recorder(
        keyedBy key: ObjectIdentifier,
        in path: WritableKeyPath<State, [ObjectIdentifier: StreamSessionRecorder]>,
        streamID: String
    ) -> StreamSessionRecorder {
        lock.withLockUnchecked { state in
            if let existing = state[keyPath: path][key] {
                return existing
            }
            let recorder = StreamSessionRecorder(
                hub: hub,
                streamID: streamID,
                transport: .webRTC,
                tags: baseTags
            )
            state[keyPath: path][key] = recorder
            return recorder
        }
    }
}
