import SwiftUI

struct SourcesView: View {
    @Bindable var sources: DemoSources

    var body: some View {
        Form {
            Section("HTTP") {
                Toggle("Periodic Requests", isOn: Binding(
                    get: { sources.isPollingHTTP },
                    set: { sources.setHTTPPolling($0) }
                ))
                Button("Request Now") {
                    sources.requestNow()
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
