import Foundation
import LiveKit
import Observation
import SRTCore
import SRTLibsrt
import TelemetryHub
import TelemetryHubLiveKit
import TelemetryHubSRT

@MainActor
@Observable
final class DemoSources {
    private(set) var isPollingHTTP = false
    private(set) var isWebSocketConnected = false
    private(set) var isSRTRunning = false
    private(set) var srtStatus: String?
    private(set) var isLiveKitConnected = false
    private(set) var isCameraEnabled = false
    private(set) var isMicrophoneEnabled = false
    var liveKitURL = ""
    var liveKitToken = ""
    private(set) var liveKitStatus: String?

    @ObservationIgnored private let httpCollector = URLSessionTelemetryCollector()
    @ObservationIgnored private lazy var httpSession = URLSession(
        configuration: .default,
        delegate: httpCollector,
        delegateQueue: nil
    )
    @ObservationIgnored private var httpTask: Task<Void, Never>?
    @ObservationIgnored private var httpEndpointIndex = 0

    @ObservationIgnored private var webSocketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var webSocketRecorder: SocketRecorder?
    @ObservationIgnored private var webSocketLoops: [Task<Void, Never>] = []

    @ObservationIgnored private var srtListener: LibsrtTransport?
    @ObservationIgnored private var srtCaller: LibsrtTransport?
    @ObservationIgnored private var srtObserver: SRTTelemetryObserver?
    @ObservationIgnored private var srtLoops: [Task<Void, Never>] = []

    @ObservationIgnored private var room: Room?
    @ObservationIgnored private var liveKitObserver: LiveKitTelemetryObserver?

    private static let httpEndpoints = [
        "https://www.apple.com/library/test/success.html",
        "https://www.gstatic.com/generate_204",
        "https://speed.cloudflare.com/__down?bytes=131072",
    ]

    func setHTTPPolling(_ enabled: Bool) {
        guard enabled != isPollingHTTP else { return }
        isPollingHTTP = enabled
        if enabled {
            httpTask = Task { [weak self] in
                while !Task.isCancelled {
                    self?.requestNow()
                    try? await Task.sleep(for: .seconds(5))
                }
            }
        } else {
            httpTask?.cancel()
            httpTask = nil
        }
    }

    func requestNow() {
        let endpoint = Self.httpEndpoints[httpEndpointIndex % Self.httpEndpoints.count]
        httpEndpointIndex += 1
        guard let url = URL(string: endpoint) else { return }
        let session = httpSession
        Task {
            _ = try? await session.data(from: url)
        }
    }

    func setWebSocket(_ enabled: Bool) {
        if enabled {
            connectWebSocket()
        } else {
            disconnectWebSocket(task: nil, error: nil)
        }
    }

    private func connectWebSocket() {
        guard webSocketTask == nil, let url = URL(string: "wss://echo.websocket.org") else { return }
        let recorder = SocketRecorder(label: "echo", transport: .webSocket)
        let task = URLSession.shared.webSocketTask(with: url)
        webSocketRecorder = recorder
        webSocketTask = task
        isWebSocketConnected = true
        task.resume()
        recorder.didConnect()

        webSocketLoops.append(Task { [weak self] in
            while !Task.isCancelled {
                do {
                    switch try await task.receive() {
                    case .string(let text):
                        recorder.didReceive(bytes: text.utf8.count)
                    case .data(let data):
                        recorder.didReceive(bytes: data.count)
                    @unknown default:
                        break
                    }
                } catch {
                    self?.disconnectWebSocket(task: task, error: error)
                    return
                }
            }
        })

        webSocketLoops.append(Task { [weak self] in
            var counter = 0
            while !Task.isCancelled {
                counter += 1
                let payload = "telemetry-demo \(counter) \(Date().timeIntervalSince1970)"
                do {
                    try await task.send(.string(payload))
                    recorder.didSend(bytes: payload.utf8.count)
                    try await Task.sleep(for: .seconds(2))
                } catch is CancellationError {
                    return
                } catch {
                    self?.disconnectWebSocket(task: task, error: error)
                    return
                }
            }
        })

        webSocketLoops.append(Task {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(5))
                } catch {
                    return
                }
                let start = Date()
                let pongReceived: Bool = await withCheckedContinuation { continuation in
                    task.sendPing { error in
                        continuation.resume(returning: error == nil)
                    }
                }
                if pongReceived {
                    recorder.didMeasureRoundTrip(milliseconds: Date().timeIntervalSince(start) * 1000)
                }
            }
        })
    }

    private func disconnectWebSocket(task: URLSessionWebSocketTask?, error: (any Error)?) {
        guard let current = webSocketTask, task == nil || task === current else { return }
        webSocketLoops.forEach { $0.cancel() }
        webSocketLoops.removeAll()
        current.cancel(with: .goingAway, reason: nil)
        webSocketRecorder?.didDisconnect(error: error)
        webSocketRecorder = nil
        webSocketTask = nil
        isWebSocketConnected = false
    }

    func setSRT(_ enabled: Bool) {
        if enabled {
            startSRT()
        } else {
            stopSRT()
        }
    }

    private func startSRT() {
        guard srtCaller == nil else { return }
        let port: UInt16 = 9710
        let listener = LibsrtTransport(configuration: SRTConfiguration(
            mode: .listener,
            local: SRTEndpoint(host: "127.0.0.1", port: port)
        ))
        let caller = LibsrtTransport(configuration: SRTConfiguration(
            mode: .caller,
            remote: SRTEndpoint(host: "127.0.0.1", port: port)
        ))
        let observer = SRTTelemetryObserver(streamID: "loopback")
        srtListener = listener
        srtCaller = caller
        srtObserver = observer
        isSRTRunning = true
        observer.observe(transport: caller)

        srtLoops.append(Task { [weak self] in
            do {
                try await listener.open()
                while !Task.isCancelled {
                    do {
                        _ = try await listener.receive(maximumSize: 1_456)
                    } catch LibsrtError.receiveTimedOut {
                        continue
                    }
                }
            } catch is CancellationError {
            } catch LibsrtError.notConnected {
            } catch {
                self?.srtStatus = "Listener: \(error.localizedDescription)"
            }
        })

        srtLoops.append(Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(250))
                try await caller.open()
                let payload = Data(repeating: 0x55, count: 1_316)
                while !Task.isCancelled {
                    for _ in 0..<8 {
                        try await caller.send(payload, sourceTimeMicroseconds: nil)
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
            } catch is CancellationError {
            } catch LibsrtError.notConnected {
            } catch {
                self?.srtStatus = "Caller: \(error.localizedDescription)"
            }
        })
    }

    private func stopSRT() {
        guard srtCaller != nil else { return }
        let listener = srtListener
        let caller = srtCaller
        let observer = srtObserver
        let loops = srtLoops
        srtObserver = nil
        srtListener = nil
        srtCaller = nil
        srtLoops = []
        isSRTRunning = false
        srtStatus = nil
        Task {
            loops.forEach { $0.cancel() }
            await caller?.close()
            await listener?.close()
            await observer?.finish()
        }
    }

    func connectLiveKit() {
        guard room == nil else { return }
        let url = liveKitURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = liveKitToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty, !token.isEmpty else { return }
        let observer = LiveKitTelemetryObserver()
        let newRoom = Room(
            delegate: observer,
            roomOptions: RoomOptions(reportRemoteTrackStatistics: true)
        )
        observer.observe(room: newRoom)
        room = newRoom
        liveKitObserver = observer
        liveKitStatus = "Connecting"
        Task { [weak self] in
            do {
                try await newRoom.connect(url: url, token: token)
                self?.isLiveKitConnected = true
                self?.liveKitStatus = nil
            } catch {
                self?.liveKitStatus = String(describing: error)
                self?.room = nil
                self?.liveKitObserver = nil
            }
        }
    }

    func disconnectLiveKit() {
        guard let room else { return }
        let observer = liveKitObserver
        self.room = nil
        liveKitObserver = nil
        isLiveKitConnected = false
        isCameraEnabled = false
        isMicrophoneEnabled = false
        liveKitStatus = nil
        Task {
            await room.disconnect()
            observer?.stopObserving(room: room)
        }
    }

    func setCamera(_ enabled: Bool) {
        guard let room else { return }
        Task { [weak self] in
            do {
                _ = try await room.localParticipant.setCamera(enabled: enabled)
                self?.isCameraEnabled = enabled
            } catch {
                self?.liveKitStatus = String(describing: error)
            }
        }
    }

    func setMicrophone(_ enabled: Bool) {
        guard let room else { return }
        Task { [weak self] in
            do {
                _ = try await room.localParticipant.setMicrophone(enabled: enabled)
                self?.isMicrophoneEnabled = enabled
            } catch {
                self?.liveKitStatus = String(describing: error)
            }
        }
    }
}
