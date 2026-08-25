# TelemetryHub

Telemetry collection for Swift apps: one pipeline for metrics, events, and request traces from streaming, networking, and system sources, with pluggable exporters and a drop-in SwiftUI metrics panel.

## Modules

| Product | What it does | Extra dependencies |
|---|---|---|
| `TelemetryHub` | Core pipeline: `Telemetry` hub, signal model, recorders, built-in collectors (connectivity, URLSession, system stats), `MetricsStore` for UI | none |
| `TelemetryHubNIO` | SwiftNIO channel handlers for TCP, UDP datagram, and WebSocket frame metrics | swift-nio |
| `TelemetryHubGRPC` | grpc-swift-2 client interceptor (per-RPC duration, status, failures) | grpc-swift-2 (GRPCCore) |
| `TelemetryHubLiveKit` | WebRTC stats via LiveKit rooms/tracks (bitrate, RTT, loss, jitter, fps, freezes) | livekit/client-sdk-swift |
| `TelemetryHubSRT` | SRT transport stats via SRTKit (Saver SDK) | SRTKit (local, `SRTCore` product) |
| `TelemetryHubSentry` | Exporter mapping signals to Sentry metrics, logs, breadcrumbs, and transactions | sentry-cocoa |
| `TelemetryHubUI` | Turnkey SwiftUI metrics panel (Swift Charts) | none |

Platforms: iOS 17+, macOS 14+. Swift 6 language mode. `TelemetryHubGRPC` requires iOS 18/macOS 15 at the call site (grpc-swift-2's floor, enforced with `@available`).

## Core concepts

Everything flows through a `Telemetry` hub as one of three signal types:

- **`TelemetryMetric`** — numeric samples: counters, gauges, histograms, each with a unit and tags.
- **`TelemetryEvent`** — discrete happenings: connection state changes, failures.
- **`TelemetryTrace`** — completed operations with a duration and status: HTTP requests, gRPC calls.

Signals buffer in the hub and flush on an interval (default 1 s) to every registered `TelemetryExporter`, and into `hub.store` (a `MetricsStore`, `@Observable`, main-actor) which retains rolling history for UI.

```swift
import TelemetryHub

let hub = Telemetry.shared
hub.add(source: ConnectivitySource())
hub.add(source: SystemStatsSource())
hub.add(exporter: LogExporter())
hub.start()

hub.gauge("stream.rtt", 42, unit: .milliseconds, tags: ["stream": "cam-1"])
hub.counter("net.retry.count")
hub.event("uplink.handoff", message: "wifi → cellular", level: .warning)
```

### Recorders

Recorders map domain-specific measurements onto canonical metric names so every adapter, exporter, and the UI agree on vocabulary:

- `StreamSessionRecorder` — media streams (WebRTC, SRT, custom): feed it `StreamStatsSample`s, get `stream.bitrate.out`, `stream.rtt`, `stream.packets.loss`, `stream.fps`, … plus `stream.state` events.
- `SocketRecorder` — sockets (TCP/UDP/WebSocket): byte/message counters plus derived `socket.throughput.in/out` gauges on a 1 s window.
- `NetworkRequestRecorder` — request/response calls: `begin(name:)` → `end(token:status:)` emits a trace, duration histogram, and failure counters.

Adapters below are thin wrappers around these; anything they don't cover you can record directly.

## Sources

### Connectivity

`ConnectivitySource` watches `NWPathMonitor`: `connectivity.status`, interface type, expensive/constrained flags, and a `connectivity.change` event on transitions.

### URLSession

```swift
let collector = URLSessionTelemetryCollector()
let session = URLSession(configuration: .default, delegate: collector, delegateQueue: nil)
```

Emits per request: `net.http.duration`, `net.http.ttfb`, `net.http.dns`, `net.http.connect`, `net.http.tls`, byte counters, failure events, and a `TelemetryTrace`. If your session already has a delegate, forward `urlSession(_:task:didFinishCollecting:)` and `urlSession(_:task:didCompleteWithError:)` to a collector instance.

### System stats

`SystemStatsSource` samples every 5 s: `system.cpu`, `system.memory.footprint`, `system.thermal` (with change events), and `system.battery` on iOS.

### WebRTC via LiveKit (`TelemetryHubLiveKit`)

```swift
import TelemetryHubLiveKit

let observer = LiveKitTelemetryObserver()
let room = Room(
    delegate: observer,
    roomOptions: RoomOptions(reportRemoteTrackStatistics: true)
)
observer.observe(room: room)
```

`reportRemoteTrackStatistics: true` is required — LiveKit's stats timer is off by default. The observer attaches to tracks as they publish/subscribe and maps LiveKit's per-second `TrackStatistics` into stream metrics (per-track bitrate, RTT from remote-inbound reports, loss, jitter, fps, resolution, freezes, bandwidth estimate) plus room connection state and quality. Retain the observer — LiveKit holds delegates weakly.

### SRT via SRTKit (`TelemetryHubSRT`)

Works with any `SRTTransport` (e.g. `LibsrtTransport`):

```swift
import TelemetryHubSRT

let observer = SRTTelemetryObserver(streamID: "uplink")
observer.observe(transport: transport)
```

The observer consumes `transport.events` for connection state and statistics snapshots, and polls `statistics(clear: false)` (default 1 s, `pollInterval: nil` to disable) while connected. Emits RTT, bitrate in/out (from byte deltas), bandwidth estimate, packets sent/received/lost/retransmitted, and windowed loss percentage.

`transport.events` is a single-consumer `AsyncStream`, so the observer must be its only consumer, and observation is one-shot: one observer per transport session, later `observe` calls are ignored. Create a fresh transport + observer pair per session. To tear down, `await transport.close()` then `await observer.finish()` — that drains the final `.closing`/`.closed` events so the disconnect is recorded; `stop()` cancels immediately instead, dropping any undelivered events and ending the transport's stream.

### gRPC (`TelemetryHubGRPC`)

```swift
import TelemetryHubGRPC

let client = GRPCClient(
    transport: transport,
    interceptors: [TelemetryClientInterceptor()]
)
```

Records `/package.Service/Method` traces with duration and status code (`net.grpc.duration`, `net.grpc.count`, `net.grpc.failure.count`). Durations cover the full RPC including response-body consumption. On grpc-swift v1 (maintenance mode) use `NetworkRequestRecorder(kind: .grpcCall)` from a v1 interceptor in your app instead.

### Raw sockets via SwiftNIO (`TelemetryHubNIO`)

Add a handler to any pipeline:

```swift
channel.pipeline.addHandler(TelemetryChannelHandler(label: "control", transport: .tcp))
channel.pipeline.addHandler(TelemetryDatagramHandler(label: "discovery"))
channel.pipeline.addHandler(TelemetryWebSocketHandler(label: "signaling"))
```

The WebSocket handler counts data frames and measures ping/pong RTT. For `URLSessionWebSocketTask`, drive a `SocketRecorder` from your send/receive paths.

## Exporters

### Sentry (`TelemetryHubSentry`)

```swift
import Sentry
import TelemetryHubSentry

SentrySDK.start { options in
    options.dsn = "…"
    options.enableLogs = true
    options.tracesSampleRate = 1.0
}
Telemetry.shared.add(exporter: SentryExporter())
```

Mapping: gauges → `SentrySDK.metrics.gauge`, counters → `metrics.count`, histograms → `metrics.distribution`; events → structured logs (and optionally breadcrumbs); traces → transactions with tags and measurements. Requires sentry-cocoa 9.12+ (the attribute-based metrics API). Configure per-signal behavior with `SentryExporterConfiguration`.

### Custom

Conform to `TelemetryExporter` — one async `export(_:)` over signal batches. `LogExporter` (os.Logger) and `InMemoryExporter` (tests) ship in core.

## UI (`TelemetryHubUI`)

```swift
import TelemetryHubUI

MetricsPanel()
```

`MetricsPanel` is a self-contained `NavigationStack`; use `MetricsPanelView` to embed in your own navigation. Grouped live series with sparklines, per-metric detail charts, recent events, and request lists — all reading `hub.store`.

## Example

`Example/ExampleApp` is a runnable iOS/macOS app showing the metrics panel fed by real sources, toggled from the Sources screen:

- Connectivity and system stats run from launch.
- HTTP: real requests (one-shot or every 5 s) through an instrumented `URLSession`.
- WebSocket: a live connection to `wss://echo.websocket.org` with echoed messages and ping-derived RTT.
- SRT: an in-process loopback pair of `LibsrtTransport`s (listener + caller over `127.0.0.1:9710`) pumping ~100 KB/s of real SRT traffic, observed by `SRTTelemetryObserver`.
- LiveKit: paste a server URL + token to join a real room; camera/microphone publish toggles feed live WebRTC stats through `LiveKitTelemetryObserver`.
