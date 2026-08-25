import Foundation
import os
#if canImport(UIKit)
import UIKit
#endif

public final class SystemStatsSource: TelemetrySource, @unchecked Sendable {
    public let sourceID = "system"

    private struct State {
        var task: Task<Void, Never>?
        var lastThermalState: ProcessInfo.ThermalState?
    }

    private let interval: TimeInterval
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    public init(interval: TimeInterval = 5.0) {
        self.interval = interval
    }

    public func start(hub: Telemetry) {
        stop()
        #if canImport(UIKit)
        Task { @MainActor in
            UIDevice.current.isBatteryMonitoringEnabled = true
        }
        #endif
        let interval = self.interval
        let task = Task { [weak self, weak hub] in
            while !Task.isCancelled {
                do {
                    guard let self, let hub else { return }
                    await self.sample(into: hub)
                }
                try? await Task.sleep(for: .seconds(interval))
            }
        }
        lock.withLock { $0.task = task }
    }

    deinit {
        lock.withLock { $0.task }?.cancel()
    }

    public func stop() {
        let task = lock.withLock { state -> Task<Void, Never>? in
            let task = state.task
            state.task = nil
            return task
        }
        task?.cancel()
    }

    private func sample(into hub: Telemetry) async {
        if let footprint = Self.memoryFootprint() {
            hub.gauge("system.memory.footprint", Double(footprint), unit: .bytes)
        }
        if let cpu = Self.cpuUsagePercent() {
            hub.gauge("system.cpu", cpu, unit: .percent)
        }

        let thermal = ProcessInfo.processInfo.thermalState
        hub.gauge("system.thermal", Double(thermal.rawValue))
        let previous = lock.withLock { state -> ProcessInfo.ThermalState? in
            let previous = state.lastThermalState
            state.lastThermalState = thermal
            return previous
        }
        if let previous, previous != thermal {
            hub.event(
                "system.thermal.change",
                message: Self.thermalLabel(thermal),
                level: thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue ? .warning : .info,
                tags: ["state": Self.thermalLabel(thermal)]
            )
        }

        #if canImport(UIKit)
        let battery = await MainActor.run { UIDevice.current.batteryLevel }
        if battery >= 0 {
            hub.gauge("system.battery", Double(battery) * 100, unit: .percent)
        }
        #endif
    }

    private static func memoryFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { reboundPointer in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), reboundPointer, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return info.phys_footprint
    }

    private static func cpuUsagePercent() -> Double? {
        var threadList: thread_act_array_t?
        var threadCount = mach_msg_type_number_t(0)
        guard task_threads(mach_task_self_, &threadList, &threadCount) == KERN_SUCCESS,
              let threadList
        else { return nil }
        defer {
            let size = vm_size_t(UInt64(threadCount) * UInt64(MemoryLayout<thread_t>.stride))
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: threadList)), size)
        }

        var total: Double = 0
        for index in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var infoCount = mach_msg_type_number_t(THREAD_INFO_MAX)
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) { reboundPointer in
                    thread_info(threadList[index], thread_flavor_t(THREAD_BASIC_INFO), reboundPointer, &infoCount)
                }
            }
            guard result == KERN_SUCCESS else { continue }
            if info.flags & TH_FLAGS_IDLE == 0 {
                total += Double(info.cpu_usage) / Double(TH_USAGE_SCALE) * 100
            }
        }
        return total
    }

    private static func thermalLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}
