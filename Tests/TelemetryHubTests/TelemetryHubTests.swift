import Foundation
import Testing
@testable import TelemetryHub

@Suite struct HubPipelineTests {
    @Test func recordedSignalsReachExporterOnFlush() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        hub.gauge("test.gauge", 42, unit: .milliseconds)
        hub.counter("test.counter", by: 3)
        hub.event("test.event", message: "hello", level: .warning)
        await hub.flush()

        #expect(exporter.metrics.count == 2)
        #expect(exporter.events.count == 1)
        let gauge = exporter.metrics.first { $0.name == "test.gauge" }
        #expect(gauge?.value == 42)
        #expect(gauge?.unit == .milliseconds)
        #expect(exporter.events.first?.level == .warning)
    }

    @Test func flushDrainsBuffer() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        hub.gauge("test.gauge", 1)
        await hub.flush()
        await hub.flush()

        #expect(exporter.metrics.count == 1)
    }

    @Test func globalTagsAreApplied() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(
            flushInterval: 60,
            globalTags: ["app": "example"]
        ))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        hub.gauge("test.gauge", 1, tags: ["local": "tag"])
        await hub.flush()

        let metric = exporter.metrics.first
        #expect(metric?.tags["app"] == "example")
        #expect(metric?.tags["local"] == "tag")
    }

    @Test func globalTagsDoNotOverrideLocalTags() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(
            flushInterval: 60,
            globalTags: ["key": "global"]
        ))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        hub.gauge("test.gauge", 1, tags: ["key": "local"])
        await hub.flush()

        #expect(exporter.metrics.first?.tags["key"] == "local")
    }

    @Test func disabledHubRecordsNothing() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(isEnabled: false))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        hub.gauge("test.gauge", 1)
        await hub.flush()

        #expect(exporter.signals.isEmpty)
    }

    @Test func bufferIsCapped() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(
            flushInterval: 60,
            maxBufferedSignals: 10
        ))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)

        for index in 0..<25 {
            hub.gauge("test.gauge", Double(index))
        }
        await hub.flush()

        #expect(exporter.metrics.count == 10)
        #expect(exporter.metrics.first?.value == 15)
        #expect(exporter.metrics.last?.value == 24)
    }

    @Test func duplicateExporterIDReplacesExisting() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let first = InMemoryExporter()
        let second = InMemoryExporter()
        hub.add(exporter: first)
        hub.add(exporter: second)

        hub.gauge("test.gauge", 1)
        await hub.flush()

        #expect(first.signals.isEmpty)
        #expect(second.metrics.count == 1)
    }
}

@Suite @MainActor struct MetricsStoreTests {
    @Test func gaugeKeepsLastValue() {
        let store = MetricsStore()
        store.ingest([
            .metric(TelemetryMetric(name: "a.gauge", kind: .gauge, value: 1)),
            .metric(TelemetryMetric(name: "a.gauge", kind: .gauge, value: 5)),
        ])
        #expect(store.series["a.gauge"]?.lastValue == 5)
        #expect(store.series["a.gauge"]?.points.count == 2)
    }

    @Test func counterAccumulates() {
        let store = MetricsStore()
        store.ingest([
            .metric(TelemetryMetric(name: "a.counter", kind: .counter, value: 2)),
            .metric(TelemetryMetric(name: "a.counter", kind: .counter, value: 3)),
        ])
        #expect(store.series["a.counter"]?.lastValue == 5)
    }

    @Test func tagsCreateSeparateSeries() {
        let store = MetricsStore()
        store.ingest([
            .metric(TelemetryMetric(name: "a.gauge", kind: .gauge, value: 1, tags: ["host": "x"])),
            .metric(TelemetryMetric(name: "a.gauge", kind: .gauge, value: 2, tags: ["host": "y"])),
        ])
        #expect(store.series.count == 2)
    }

    @Test func historyIsCapped() {
        let store = MetricsStore(historyLimit: 5)
        let signals = (0..<10).map {
            TelemetrySignal.metric(TelemetryMetric(name: "a.gauge", kind: .gauge, value: Double($0)))
        }
        store.ingest(signals)
        let series = store.series["a.gauge"]
        #expect(series?.points.count == 5)
        #expect(series?.points.first?.value == 5)
        #expect(series?.points.last?.value == 9)
    }

    @Test func eventsAndTracesAreCapped() {
        let store = MetricsStore(eventLimit: 3, traceLimit: 2)
        let events = (0..<5).map {
            TelemetrySignal.event(TelemetryEvent(name: "event.\($0)"))
        }
        let traces = (0..<4).map {
            TelemetrySignal.trace(TelemetryTrace(name: "trace.\($0)", kind: .custom, start: Date(), duration: 0.1))
        }
        store.ingest(events + traces)
        #expect(store.events.count == 3)
        #expect(store.traces.count == 2)
        #expect(store.events.first?.name == "event.2")
    }

    @Test func groupUsesFirstNameComponent() {
        let store = MetricsStore()
        store.ingest([
            .metric(TelemetryMetric(name: "stream.bitrate.out", kind: .gauge, value: 1)),
        ])
        #expect(store.series["stream.bitrate.out"]?.group == "stream")
    }

    @Test func seriesIDIsStableAcrossTagOrder() {
        let a = MetricsStore.seriesID(name: "n", tags: ["a": "1", "b": "2"])
        let b = MetricsStore.seriesID(name: "n", tags: ["b": "2", "a": "1"])
        #expect(a == b)
    }
}

@Suite struct RecorderTests {
    @Test func networkRequestRecorderEmitsTraceAndMetrics() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let recorder = NetworkRequestRecorder(hub: hub, kind: .grpcCall)

        let token = recorder.begin(name: "/pkg.Service/Method")
        recorder.end(token, status: .ok, bytesSent: 100, bytesReceived: 250)
        await hub.flush()

        let trace = exporter.traces.first
        #expect(trace?.name == "/pkg.Service/Method")
        #expect(trace?.kind == .grpcCall)
        #expect(trace?.status == .ok)
        #expect(trace?.measurements["bytes.sent"] == 100)
        #expect(exporter.metrics.contains { $0.name == "net.grpc.duration" })
        #expect(exporter.metrics.contains { $0.name == "net.grpc.count" })
        #expect(!exporter.metrics.contains { $0.name == "net.grpc.failure.count" })
    }

    @Test func networkRequestRecorderEmitsFailureSignals() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let recorder = NetworkRequestRecorder(hub: hub)

        let token = recorder.begin(name: "GET example.com/things")
        recorder.end(token, status: .error("timeout"))
        await hub.flush()

        #expect(exporter.traces.first?.status.isError == true)
        #expect(exporter.metrics.contains { $0.name == "net.http.failure.count" })
        #expect(exporter.events.contains { $0.name == "net.http.failure" && $0.level == .error })
    }

    @Test func streamRecorderMapsSampleToCanonicalNames() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let recorder = StreamSessionRecorder(hub: hub, streamID: "cam-1", transport: .webRTC)

        recorder.record(StreamStatsSample(
            bitrateOut: 2_500_000,
            packetsLost: 12,
            roundTripTimeMs: 45,
            framesPerSecond: 30
        ))
        await hub.flush()

        let names = Set(exporter.metrics.map(\.name))
        #expect(names == ["stream.bitrate.out", "stream.packets.lost", "stream.rtt", "stream.fps"])
        let bitrate = exporter.metrics.first { $0.name == "stream.bitrate.out" }
        #expect(bitrate?.tags["stream"] == "cam-1")
        #expect(bitrate?.tags["transport"] == "webrtc")
        #expect(bitrate?.unit == .bitsPerSecond)
    }

    @Test func streamRecorderStateChangeEmitsEvent() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let recorder = StreamSessionRecorder(hub: hub, streamID: "cam-1", transport: .srt)

        recorder.recordState(.failed, message: "handshake timeout")
        await hub.flush()

        let event = exporter.events.first
        #expect(event?.name == "stream.state")
        #expect(event?.level == .error)
        #expect(event?.tags["state"] == "failed")
        #expect(exporter.metrics.contains { $0.name == "stream.connected" && $0.value == 0 })
    }

    @Test func socketRecorderCountsBytesAndMessages() async {
        let hub = Telemetry(configuration: TelemetryConfiguration(flushInterval: 60))
        let exporter = InMemoryExporter()
        hub.add(exporter: exporter)
        let recorder = SocketRecorder(hub: hub, label: "control", transport: .webSocket)

        recorder.didConnect()
        recorder.didSend(bytes: 128)
        recorder.didReceive(bytes: 512, messages: 2)
        recorder.didDisconnect()
        await hub.flush()

        #expect(exporter.metrics.contains { $0.name == "socket.bytes.out" && $0.value == 128 })
        #expect(exporter.metrics.contains { $0.name == "socket.bytes.in" && $0.value == 512 })
        #expect(exporter.metrics.contains { $0.name == "socket.messages.in" && $0.value == 2 })
        #expect(exporter.events.contains { $0.name == "socket.connected" })
        #expect(exporter.events.contains { $0.name == "socket.disconnected" })
        let connected = exporter.metrics.filter { $0.name == "socket.connected" }
        #expect(connected.map(\.value) == [1, 0])
    }
}
