import Foundation
import Observation

@MainActor
@Observable
public final class MetricsStore {
    public struct Point: Sendable, Hashable {
        public let timestamp: Date
        public let value: Double
    }

    public struct Series: Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let tags: [String: String]
        public let unit: TelemetryUnit
        public let kind: MetricKind
        public internal(set) var points: [Point]
        public internal(set) var lastValue: Double
        public internal(set) var lastUpdated: Date

        public var group: String {
            name.split(separator: ".").first.map(String.init) ?? name
        }

        public var minValue: Double {
            points.lazy.map(\.value).min() ?? lastValue
        }

        public var maxValue: Double {
            points.lazy.map(\.value).max() ?? lastValue
        }
    }

    public private(set) var series: [String: Series] = [:]
    public private(set) var events: [TelemetryEvent] = []
    public private(set) var traces: [TelemetryTrace] = []

    private let historyLimit: Int
    private let eventLimit: Int
    private let traceLimit: Int

    public nonisolated init(historyLimit: Int = 600, eventLimit: Int = 200, traceLimit: Int = 200) {
        self.historyLimit = historyLimit
        self.eventLimit = eventLimit
        self.traceLimit = traceLimit
    }

    public var sortedSeries: [Series] {
        series.values.sorted { lhs, rhs in
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.id < rhs.id
        }
    }

    public var groupedSeries: [(group: String, series: [Series])] {
        Dictionary(grouping: sortedSeries, by: \.group)
            .sorted { $0.key < $1.key }
            .map { (group: $0.key, series: $0.value) }
    }

    public func ingest(_ signals: [TelemetrySignal]) {
        for signal in signals {
            switch signal {
            case .metric(let metric):
                ingest(metric)
            case .event(let event):
                events.append(event)
            case .trace(let trace):
                traces.append(trace)
            }
        }
        if events.count > eventLimit {
            events.removeFirst(events.count - eventLimit)
        }
        if traces.count > traceLimit {
            traces.removeFirst(traces.count - traceLimit)
        }
    }

    public func removeAll() {
        series.removeAll()
        events.removeAll()
        traces.removeAll()
    }

    private func ingest(_ metric: TelemetryMetric) {
        let id = Self.seriesID(name: metric.name, tags: metric.tags)
        var entry = series[id] ?? Series(
            id: id,
            name: metric.name,
            tags: metric.tags,
            unit: metric.unit,
            kind: metric.kind,
            points: [],
            lastValue: 0,
            lastUpdated: metric.timestamp
        )
        let value: Double
        switch metric.kind {
        case .counter:
            value = entry.points.isEmpty && entry.lastValue == 0
                ? metric.value
                : entry.lastValue + metric.value
        case .gauge, .histogram:
            value = metric.value
        }
        entry.lastValue = value
        entry.lastUpdated = metric.timestamp
        entry.points.append(Point(timestamp: metric.timestamp, value: value))
        if entry.points.count > historyLimit {
            entry.points.removeFirst(entry.points.count - historyLimit)
        }
        series[id] = entry
    }

    static func seriesID(name: String, tags: [String: String]) -> String {
        guard !tags.isEmpty else { return name }
        let separator = "\u{1F}"
        let suffix = tags.sorted { $0.key < $1.key }
            .map { "\($0.key)\(separator)\($0.value)" }
            .joined(separator: separator)
        return "\(name)\(separator)\(suffix)"
    }
}
