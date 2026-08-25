import SwiftUI

struct SourcesView: View {
    @Bindable var sources: DemoSources

    var body: some View {
        Form {
            Section("Network Probe") {
                Toggle("Continuous Sampling", isOn: Binding(
                    get: { sources.isPollingNetwork },
                    set: { sources.setNetworkPolling($0) }
                ))
                Button(sources.isProbingNetwork ? "Testing…" : "Run Speed Test") {
                    sources.probeNetworkNow()
                }
                .disabled(sources.isProbingNetwork)
                LabeledContent("Service", value: "Cloudflare Speed")
                Text("The full test transfers 4 MB down and 1 MB up. Continuous sampling runs every 30 seconds with lighter 512 KB / 128 KB transfers to reduce CPU and data use.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let status = sources.networkStatus {
                    Text(status)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Section("HTTP") {
                Toggle("Periodic Requests", isOn: Binding(
                    get: { sources.isPollingHTTP },
                    set: { sources.setHTTPPolling($0) }
                ))
                Button("Request Now") {
                    sources.requestNow()
                }
            }
            Section("gRPC") {
                Button(sources.isProbingGRPC ? "Calling…" : "Run gRPC Probe") {
                    sources.probeGRPCNow()
                }
                .disabled(sources.isProbingGRPC)
                LabeledContent("Endpoint", value: "grpcb.in:9001")
                Text("Makes a real TLS unary call and records its full lifecycle as a gRPC trace.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let status = sources.grpcStatus {
                    Text(status)
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Section("WebSocket") {
                Toggle("Echo Connection", isOn: Binding(
                    get: { sources.isWebSocketConnected },
                    set: { sources.setWebSocket($0) }
                ))
                LabeledContent("Endpoint", value: "wss://echo.websocket.org")
            }
            Section("SRT") {
                Toggle("Loopback Stream", isOn: Binding(
                    get: { sources.isSRTRunning },
                    set: { sources.setSRT($0) }
                ))
                LabeledContent("Endpoint", value: "srt://127.0.0.1:9710")
                if let status = sources.srtStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            Section("LiveKit") {
                TextField("URL", text: $sources.liveKitURL)
                    .autocorrectionDisabled()
                TextField("Token", text: $sources.liveKitToken)
                    .autocorrectionDisabled()
                if sources.isLiveKitConnected {
                    Toggle("Camera", isOn: Binding(
                        get: { sources.isCameraEnabled },
                        set: { sources.setCamera($0) }
                    ))
                    Toggle("Microphone", isOn: Binding(
                        get: { sources.isMicrophoneEnabled },
                        set: { sources.setMicrophone($0) }
                    ))
                    Button("Disconnect", role: .destructive) {
                        sources.disconnectLiveKit()
                    }
                } else {
                    Button("Connect") {
                        sources.connectLiveKit()
                    }
                    .disabled(sources.liveKitURL.isEmpty || sources.liveKitToken.isEmpty)
                }
                if let status = sources.liveKitStatus {
                    Text(status)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Sources")
        #if os(iOS)
        .textInputAutocapitalization(.never)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}
