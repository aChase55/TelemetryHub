import Foundation
import SRTCore
import TelemetryHub
import os

public final class SRTTelemetryObserver: @unchecked Sendable {
    private struct State {
        var hasObserved = false
        var eventTask: Task<Void, Never>?
        var pollTask: Task<Void, Never>?
        var previous: (stats: SRTStatistics, date: Date)?
        var isConnected = false
    }

    public let streamID: String
    private let hub: Telemetry
    private let recorder: StreamSessionRecorder
    private let pollInterval: TimeInterval?
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    public init(
        hub: Telemetry = .shared,
        streamID: String,
        pollInterval: TimeInterval? = 1.0,
        tags: [String: String] = [:]
    ) {
        self.hub = hub
        self.streamID = streamID
        self.pollInterval = pollInterval
        self.recorder = StreamSessionRecorder(hub: hub, streamID: streamID, transport: .srt, tags: tags)
    }

    deinit {
        let (eventTask, pollTask) = lock.withLock { ($0.eventTask, $0.pollTask) }
        eventTask?.cancel()
        pollTask?.cancel()
    }

    public func observe(transport: any SRTTransport) {
        let interval = pollInterval
        lock.withLock { state in
            guard !state.hasObserved else { return }
            state.hasObserved = true
            let events = transport.events
            state.eventTask = Task { [weak self] in
                for await event in events {
                    guard let self else { return }
                    self.handle(event)
                }
            }
            if let interval {
                state.pollTask = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(interval))
                        guard let self else { return }
                        guard self.lock.withLock({ $0.isConnected }) else { continue }
                        _ = try? await transport.statistics(clear: false)
                    }
                }
            }
        }
    }

    public func stop() {
        let (eventTask, pollTask) = detachTasks()
        eventTask?.cancel()
        pollTask?.cancel()
    }

    public func finish() async {
        let (eventTask, pollTask) = detachTasks()
        pollTask?.cancel()
        await eventTask?.value
    }

    private func detachTasks() -> (Task<Void, Never>?, Task<Void, Never>?) {
        lock.withLock { state -> (Task<Void, Never>?, Task<Void, Never>?) in
            let tasks = (state.eventTask, state.pollTask)
            state.eventTask = nil
            state.pollTask = nil
            state.previous = nil
            state.isConnected = false
            return tasks
        }
    }

    private func handle(_ event: SRTTransportEvent) {
        switch event {
        case .stateChanged(let transportState):
            let connected = transportState == .connected
            lock.withLock { state in
                state.isConnected = connected
                if !connected {
                    state.previous = nil
                }
            }
            if let mapped = Self.streamState(for: transportState) {
                let message: String? = if case .failed(let reason) = transportState {
                    reason
                } else {
                    nil
                }
                recorder.recordState(mapped, message: message)
            }
        case .statistics(let stats):
            record(stats)
        }
    }

    private func record(_ stats: SRTStatistics) {
        let now = Date()
        let previous = lock.withLock { state -> (stats: SRTStatistics, date: Date)? in
            let previous = state.previous
            state.previous = (stats, now)
            return previous
        }

        var sample = StreamStatsSample()
        sample.bytesSent = Double(stats.bytesSent)
        sample.bytesReceived = Double(stats.bytesReceived)
        sample.packetsSent = Double(stats.packetsSent)
        sample.packetsReceived = Double(stats.packetsReceived)
        sample.packetsLost = Double(stats.packetsLost)
        sample.packetsRetransmitted = Double(stats.packetsRetransmitted)
        sample.roundTripTimeMs = stats.roundTripTimeMilliseconds
        if stats.estimatedBandwidthMbps > 0 {
            sample.bandwidthEstimate = stats.estimatedBandwidthMbps * 1_000_000
        }

        if let previous {
            let elapsed = now.timeIntervalSince(previous.date)
            if elapsed > 0.05 {
                sample.bitrateOut = Double(max(0, stats.bytesSent - previous.stats.bytesSent)) * 8 / elapsed
                sample.bitrateIn = Double(max(0, stats.bytesReceived - previous.stats.bytesReceived)) * 8 / elapsed
                let lost = max(0, stats.packetsLost - previous.stats.packetsLost)
                let sent = max(0, stats.packetsSent - previous.stats.packetsSent)
                let received = max(0, stats.packetsReceived - previous.stats.packetsReceived)
                let total = lost + sent + received
                if total > 0 {
                    sample.packetLossPercent = Double(lost) / Double(total) * 100
                }
            }
        }

        recorder.record(sample)
    }

    private static func streamState(for state: SRTTransportState) -> StreamState? {
        switch state {
        case .idle: nil
        case .opening: .connecting
        case .connected: .connected
        case .closing: nil
        case .closed: .disconnected
        case .failed: .failed
        }
    }
}
