import Foundation
import Network
import os

public final class ConnectivitySource: TelemetrySource, @unchecked Sendable {
    public let sourceID = "connectivity"

    private struct State {
        var monitor: NWPathMonitor?
        weak var hub: Telemetry?
        var lastStatusDescription: String?
    }

    private let lock = OSAllocatedUnfairLock(uncheckedState: State())
    private let queue = DispatchQueue(label: "TelemetryHub.ConnectivitySource")

    public init() {}

    deinit {
        lock.withLockUnchecked { $0.monitor }?.cancel()
    }

    public func start(hub: Telemetry) {
        stop()
        let monitor = NWPathMonitor()
        lock.withLockUnchecked { state in
            state.hub = hub
            state.monitor = monitor
        }
        monitor.pathUpdateHandler = { [weak self] path in
            self?.handle(path)
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        let monitor = lock.withLockUnchecked { state -> NWPathMonitor? in
            let monitor = state.monitor
            state.monitor = nil
            return monitor
        }
        monitor?.cancel()
    }

    private func handle(_ path: NWPath) {
        let (hub, previous) = lock.withLock { state -> (Telemetry?, String?) in
            let previous = state.lastStatusDescription
            state.lastStatusDescription = Self.describe(path)
            return (state.hub, previous)
        }
        guard let hub else { return }

        let interface = Self.primaryInterface(of: path)
        var tags: [String: String] = [
            "status": Self.statusLabel(path.status),
            "interface": interface,
            "expensive": path.isExpensive ? "true" : "false",
            "constrained": path.isConstrained ? "true" : "false",
        ]
        if path.supportsIPv4 { tags["ipv4"] = "true" }
        if path.supportsIPv6 { tags["ipv6"] = "true" }

        hub.gauge("connectivity.status", path.status == .satisfied ? 1 : 0, tags: ["interface": interface])
        hub.gauge("connectivity.expensive", path.isExpensive ? 1 : 0)
        hub.gauge("connectivity.constrained", path.isConstrained ? 1 : 0)

        let description = Self.describe(path)
        if previous != description {
            hub.event(
                "connectivity.change",
                message: description,
                level: path.status == .satisfied ? .info : .warning,
                tags: tags
            )
        }
    }

    private static func describe(_ path: NWPath) -> String {
        "\(statusLabel(path.status)) via \(primaryInterface(of: path))"
        + (path.isExpensive ? " (expensive)" : "")
        + (path.isConstrained ? " (constrained)" : "")
    }

    private static func statusLabel(_ status: NWPath.Status) -> String {
        switch status {
        case .satisfied: "satisfied"
        case .unsatisfied: "unsatisfied"
        case .requiresConnection: "requiresConnection"
        @unknown default: "unknown"
        }
    }

    private static func primaryInterface(of path: NWPath) -> String {
        if path.usesInterfaceType(.wifi) { return "wifi" }
        if path.usesInterfaceType(.cellular) { return "cellular" }
        if path.usesInterfaceType(.wiredEthernet) { return "wired" }
        if path.usesInterfaceType(.loopback) { return "loopback" }
        if path.usesInterfaceType(.other) { return "other" }
        return "none"
    }
}
