import SwiftUI
import TelemetryHub

@main
struct ExampleAppApp: App {
    init() {
        let hub = Telemetry.shared
        hub.add(source: ConnectivitySource())
        hub.add(source: SystemStatsSource())
        hub.add(exporter: LogExporter())
        hub.start()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
