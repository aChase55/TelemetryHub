import Charts
import SwiftUI
import TelemetryHub

public struct MetricsPanelView: View {
    private let store: MetricsStore

    public init(hub: Telemetry = .shared) {
        self.store = hub.store
    }

    public init(store: MetricsStore) {
        self.store = store
    }

    public var body: some View {
        List {
            if store.series.isEmpty && store.events.isEmpty && store.traces.isEmpty {
                ContentUnavailableView(
                    "No Metrics",
                    systemImage: "waveform.path.ecg",
                    description: Text("Telemetry appears here once sources start reporting.")
                )
            }
            ForEach(store.groupedSeries, id: \.group) { group in
                Section(group.group.capitalized) {
                    ForEach(group.series) { series in
                        NavigationLink(value: MetricsPanelDestination.series(series.id)) {
                            SeriesRow(series: series)
                        }
                    }
                }
            }
            if !store.traces.isEmpty {
                Section("Requests") {
                    ForEach(Array(store.traces.suffix(5).reversed().enumerated()), id: \.offset) { _, trace in
                        TraceRow(trace: trace)
                    }
                    NavigationLink("All Requests", value: MetricsPanelDestination.traces)
                }
            }
            if !store.events.isEmpty {
                Section("Events") {
                    ForEach(Array(store.events.suffix(5).reversed().enumerated()), id: \.offset) { _, event in
                        EventRow(event: event)
                    }
                    NavigationLink("All Events", value: MetricsPanelDestination.events)
                }
            }
        }
        #if os(macOS)
        .listStyle(.inset)
        #endif
        .navigationTitle("Metrics")
        .navigationDestination(for: MetricsPanelDestination.self) { destination in
            switch destination {
            case .series(let id):
                if let series = store.series[id] {
                    SeriesDetailView(store: store, seriesID: series.id)
                }
            case .events:
                EventsListView(store: store)
            case .traces:
                TracesListView(store: store)
            }
        }
    }
}

enum MetricsPanelDestination: Hashable {
    case series(String)
    case events
    case traces
}

public struct MetricsPanel: View {
    private let hub: Telemetry

    public init(hub: Telemetry = .shared) {
        self.hub = hub
    }

    public var body: some View {
        NavigationStack {
            MetricsPanelView(hub: hub)
        }
    }
}

struct SeriesRow: View {
    let series: MetricsStore.Series

    var body: some View {
        LabeledContent {
            HStack(spacing: 12) {
                SparklineView(points: series.points.suffix(60))
                Text(ValueFormatting.format(series.lastValue, unit: series.unit))
                    .monospacedDigit()
            }
        } label: {
            Text(shortName)
            if !displayTags.isEmpty {
                Text(displayTags)
            }
        }
    }

    private var shortName: String {
        let rest = series.name.split(separator: ".").dropFirst()
        return rest.isEmpty ? series.name : rest.joined(separator: ".")
    }

    private var displayTags: String {
        series.tags
            .filter { $0.key != "app" }
            .sorted { $0.key < $1.key }
            .map(\.value)
            .joined(separator: " · ")
    }
}

struct SparklineView: View {
    let points: ArraySlice<MetricsStore.Point>

    var body: some View {
        if points.count > 1 {
            Chart(Array(points.enumerated()), id: \.offset) { _, point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Value", point.value)
                )
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .frame(width: 64, height: 20)
        }
    }
}

struct EventRow: View {
    let event: TelemetryEvent

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(event.name)
                Spacer()
                Text(event.timestamp, format: .dateTime.hour().minute().second())
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .font(.callout)
            if let message = event.message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(event.level == .error ? .red : .secondary)
                    .lineLimit(2)
            }
        }
    }
}

struct TraceRow: View {
    let trace: TelemetryTrace

    var body: some View {
        LabeledContent {
            Text(ValueFormatting.duration(trace.duration))
                .monospacedDigit()
                .foregroundStyle(trace.status.isError ? .red : .secondary)
        } label: {
            Text(trace.name)
                .lineLimit(1)
            if case .error(let reason) = trace.status {
                Text(reason)
                    .lineLimit(1)
                    .foregroundStyle(.red)
            }
        }
    }
}
