import Charts
import SwiftUI
import TelemetryHub

struct SeriesDetailView: View {
    let store: MetricsStore
    let seriesID: String

    var body: some View {
        List {
            if let series = store.series[seriesID] {
                Section {
                    Chart(Array(series.points.enumerated()), id: \.offset) { _, point in
                        LineMark(
                            x: .value("Time", point.timestamp),
                            y: .value("Value", point.value)
                        )
                    }
                    .chartYAxisLabel(axisLabel(for: series.unit))
                    .frame(height: 220)
                    .listRowSeparator(.hidden)
                }
                Section {
                    LabeledContent("Current", value: ValueFormatting.format(series.lastValue, unit: series.unit))
                    LabeledContent("Minimum", value: ValueFormatting.format(series.minValue, unit: series.unit))
                    LabeledContent("Maximum", value: ValueFormatting.format(series.maxValue, unit: series.unit))
                    if series.kind != .counter {
                        LabeledContent("Average", value: ValueFormatting.format(series.averageValue, unit: series.unit))
                    }
                    if series.kind == .histogram {
                        LabeledContent("95th Percentile", value: ValueFormatting.format(series.p95Value, unit: series.unit))
                    }
                    LabeledContent("Samples", value: String(series.points.count))
                    LabeledContent("Updated") {
                        Text(series.lastUpdated, format: .dateTime.hour().minute().second())
                    }
                }
                if !series.tags.isEmpty {
                    Section("Tags") {
                        ForEach(series.tags.sorted(by: { $0.key < $1.key }), id: \.key) { tag in
                            LabeledContent(tag.key, value: tag.value)
                        }
                    }
                }
            } else {
                ContentUnavailableView("Series Removed", systemImage: "chart.xyaxis.line")
            }
        }
        .navigationTitle(store.series[seriesID]?.name ?? "Metric")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func axisLabel(for unit: TelemetryUnit) -> String {
        switch unit {
        case .none: ""
        case .count: "count"
        case .bytes: "bytes"
        case .bytesPerSecond: "B/s"
        case .bitsPerSecond: "bps"
        case .milliseconds: "ms"
        case .seconds: "s"
        case .percent: "%"
        case .framesPerSecond: "fps"
        case .pixels: "px"
        case .celsius: "°C"
        }
    }
}

struct EventsListView: View {
    let store: MetricsStore

    var body: some View {
        List {
            ForEach(Array(store.events.reversed().enumerated()), id: \.offset) { _, event in
                EventRow(event: event)
            }
        }
        .navigationTitle("Events")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

struct TracesListView: View {
    let store: MetricsStore

    var body: some View {
        List {
            ForEach(Array(store.traces.reversed().enumerated()), id: \.offset) { _, trace in
                TraceRow(trace: trace)
            }
        }
        .navigationTitle("Requests")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
