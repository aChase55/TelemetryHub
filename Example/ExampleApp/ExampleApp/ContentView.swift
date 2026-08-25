import SwiftUI
import TelemetryHub
import TelemetryHubUI

struct ContentView: View {
    @State private var sources = DemoSources()

    var body: some View {
        NavigationStack {
            MetricsPanelView()
                .toolbar {
                    ToolbarItem {
                        NavigationLink("Sources") {
                            SourcesView(sources: sources)
                        }
                    }
                }
        }
    }
}

#Preview {
    ContentView()
}
