import Foundation
import os

public final class Telemetry: Sendable {
    public static let shared = Telemetry()

    public let configuration: TelemetryConfiguration
    public let store: MetricsStore

    private struct State: Sendable {
        var buffer: [TelemetrySignal] = []
        var exporters: [any TelemetryExporter] = []
        var sources: [any TelemetrySource] = []
        var isRunning = false
        var flushTask: Task<Void, Never>?
    }

    private let state: OSAllocatedUnfairLock<State>

    public init(configuration: TelemetryConfiguration = TelemetryConfiguration()) {
        self.configuration = configuration
        self.store = MetricsStore(
            historyLimit: configuration.storeHistoryLimit,
            eventLimit: configuration.storeEventLimit,
            traceLimit: configuration.storeTraceLimit
        )
        self.state = OSAllocatedUnfairLock(initialState: State())
    }

    deinit {
        state.withLock { $0.flushTask }?.cancel()
    }

    public func record(_ signal: TelemetrySignal) {
        guard configuration.isEnabled else { return }
        let tagged = applyGlobalTags(signal)
        state.withLock { state in
            state.buffer.append(tagged)
            if state.buffer.count > configuration.maxBufferedSignals {
                state.buffer.removeFirst(state.buffer.count - configuration.maxBufferedSignals)
            }
        }
    }

    public func record(_ metric: TelemetryMetric) {
        record(.metric(metric))
    }

    public func record(_ event: TelemetryEvent) {
        record(.event(event))
    }

    public func record(_ trace: TelemetryTrace) {
        record(.trace(trace))
    }

    public func counter(
        _ name: String,
        by value: Double = 1,
        unit: TelemetryUnit = .count,
        tags: [String: String] = [:]
    ) {
        record(TelemetryMetric(name: name, kind: .counter, value: value, unit: unit, tags: tags))
    }

    public func gauge(
        _ name: String,
        _ value: Double,
        unit: TelemetryUnit = .none,
        tags: [String: String] = [:]
    ) {
        record(TelemetryMetric(name: name, kind: .gauge, value: value, unit: unit, tags: tags))
    }

    public func histogram(
        _ name: String,
        _ value: Double,
        unit: TelemetryUnit = .none,
        tags: [String: String] = [:]
    ) {
        record(TelemetryMetric(name: name, kind: .histogram, value: value, unit: unit, tags: tags))
    }

    public func event(
        _ name: String,
        message: String? = nil,
        level: TelemetryEvent.Level = .info,
        tags: [String: String] = [:]
    ) {
        record(TelemetryEvent(name: name, message: message, level: level, tags: tags))
    }

    public func add(exporter: any TelemetryExporter) {
        state.withLock { state in
            state.exporters.removeAll { $0.exporterID == exporter.exporterID }
            state.exporters.append(exporter)
        }
    }

    public func remove(exporterID: String) {
        state.withLock { $0.exporters.removeAll { $0.exporterID == exporterID } }
    }

    public func add(source: any TelemetrySource) {
        let shouldStart = state.withLock { state in
            state.sources.removeAll { $0.sourceID == source.sourceID }
            state.sources.append(source)
            return state.isRunning
        }
        if shouldStart {
            source.start(hub: self)
        }
    }

    public func remove(sourceID: String) {
        let removed = state.withLock { state in
            let matches = state.sources.filter { $0.sourceID == sourceID }
            state.sources.removeAll { $0.sourceID == sourceID }
            return matches
        }
        removed.forEach { $0.stop() }
    }

    public func start() {
        let interval = configuration.flushInterval
        let sources: [any TelemetrySource]? = state.withLock { state in
            guard !state.isRunning else { return nil }
            state.isRunning = true
            state.flushTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(interval))
                    guard let self else { return }
                    await self.flush()
                }
            }
            return state.sources
        }
        guard let sources else { return }
        sources.forEach { $0.start(hub: self) }
    }

    public func stop() {
        let (task, sources): (Task<Void, Never>?, [any TelemetrySource]) = state.withLock { state in
            let result = (state.flushTask, state.sources)
            state.flushTask = nil
            state.isRunning = false
            return result
        }
        task?.cancel()
        sources.forEach { $0.stop() }
    }

    public func flush() async {
        let (batch, exporters): ([TelemetrySignal], [any TelemetryExporter]) = state.withLock { state in
            let batch = state.buffer
            state.buffer.removeAll(keepingCapacity: true)
            return (batch, state.exporters)
        }
        guard !batch.isEmpty else { return }
        let store = self.store
        await MainActor.run { store.ingest(batch) }
        await withTaskGroup(of: Void.self) { group in
            for exporter in exporters {
                group.addTask { await exporter.export(batch) }
            }
        }
    }

    public func shutdown() async {
        stop()
        await flush()
        let exporters = state.withLock { $0.exporters }
        await withTaskGroup(of: Void.self) { group in
            for exporter in exporters {
                group.addTask { await exporter.shutdown() }
            }
        }
    }

    private func applyGlobalTags(_ signal: TelemetrySignal) -> TelemetrySignal {
        guard !configuration.globalTags.isEmpty else { return signal }
        switch signal {
        case .metric(var metric):
            metric.tags.merge(configuration.globalTags) { current, _ in current }
            return .metric(metric)
        case .event(var event):
            event.tags.merge(configuration.globalTags) { current, _ in current }
            return .event(event)
        case .trace(var trace):
            trace.tags.merge(configuration.globalTags) { current, _ in current }
            return .trace(trace)
        }
    }
}
