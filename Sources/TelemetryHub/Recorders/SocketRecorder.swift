import Foundation
import os

public enum SocketTransport: String, Sendable {
    case tcp
    case udp
    case webSocket
}

public final class SocketRecorder: Sendable {
    public let label: String
    public let transport: SocketTransport

    private struct Counters: Sendable {
        var bytesIn: Int = 0
        var bytesOut: Int = 0
        var messagesIn: Int = 0
        var messagesOut: Int = 0
        var throughputTask: Task<Void, Never>?
        var connectedAt: Date?
        var lastThroughputEmit: Date?
    }

    private let hub: Telemetry
    private let tags: [String: String]
    private let throughputInterval: TimeInterval
    private let state: OSAllocatedUnfairLock<Counters>

    public init(
        hub: Telemetry = .shared,
        label: String,
        transport: SocketTransport,
        throughputInterval: TimeInterval = 1.0,
        tags: [String: String] = [:]
    ) {
        self.hub = hub
        self.label = label
        self.transport = transport
        self.throughputInterval = throughputInterval
        var merged = tags
        merged["socket"] = label
        merged["transport"] = transport.rawValue
        self.tags = merged
        self.state = OSAllocatedUnfairLock(initialState: Counters())
    }

    deinit {
        state.withLock { $0.throughputTask }?.cancel()
    }

    public func didConnect() {
        state.withLock { state in
            state.connectedAt = Date()
            state.lastThroughputEmit = Date()
        }
        hub.event("socket.connected", message: label, tags: tags)
        hub.gauge("socket.connected", 1, tags: tags)
        startThroughputTimer()
    }

    public func didDisconnect(error: (any Error)? = nil) {
        let connectedAt = state.withLock { state -> Date? in
            state.throughputTask?.cancel()
            state.throughputTask = nil
            let at = state.connectedAt
            state.connectedAt = nil
            return at
        }
        emitThroughput()
        var tags = self.tags
        if let connectedAt {
            tags["session_seconds"] = String(Int(Date().timeIntervalSince(connectedAt)))
        }
        if let error {
            hub.event("socket.disconnected", message: "\(label): \(error)", level: .error, tags: tags)
            hub.counter("socket.failure.count", tags: self.tags)
        } else {
            hub.event("socket.disconnected", message: label, tags: tags)
        }
        hub.gauge("socket.connected", 0, tags: self.tags)
    }

    public func didSend(bytes: Int, messages: Int = 1) {
        state.withLock { state in
            state.bytesOut += bytes
            state.messagesOut += messages
        }
        hub.counter("socket.bytes.out", by: Double(bytes), unit: .bytes, tags: tags)
        hub.counter("socket.messages.out", by: Double(messages), tags: tags)
    }

    public func didReceive(bytes: Int, messages: Int = 1) {
        state.withLock { state in
            state.bytesIn += bytes
            state.messagesIn += messages
        }
        hub.counter("socket.bytes.in", by: Double(bytes), unit: .bytes, tags: tags)
        hub.counter("socket.messages.in", by: Double(messages), tags: tags)
    }

    public func didMeasureRoundTrip(milliseconds: Double) {
        hub.gauge("socket.rtt", milliseconds, unit: .milliseconds, tags: tags)
    }

    private func startThroughputTimer() {
        let interval = throughputInterval
        let task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                self.emitThroughput()
            }
        }
        state.withLock { state in
            state.throughputTask?.cancel()
            state.throughputTask = task
        }
    }

    private func emitThroughput() {
        let now = Date()
        let (bytesIn, bytesOut, elapsed) = state.withLock { state -> (Int, Int, TimeInterval) in
            let elapsed = state.lastThroughputEmit.map { now.timeIntervalSince($0) } ?? throughputInterval
            let result = (state.bytesIn, state.bytesOut, elapsed)
            state.bytesIn = 0
            state.bytesOut = 0
            state.messagesIn = 0
            state.messagesOut = 0
            state.lastThroughputEmit = now
            return result
        }
        let seconds = max(elapsed, 0.001)
        hub.gauge("socket.throughput.in", Double(bytesIn) * 8 / seconds, unit: .bitsPerSecond, tags: tags)
        hub.gauge("socket.throughput.out", Double(bytesOut) * 8 / seconds, unit: .bitsPerSecond, tags: tags)
    }
}
