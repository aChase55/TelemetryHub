import Foundation
import os

public protocol TelemetryExporter: Sendable {
    var exporterID: String { get }
    func export(_ signals: [TelemetrySignal]) async
    func flush() async
    func shutdown() async
}

extension TelemetryExporter {
    public func flush() async {}
    public func shutdown() async {}
}

public struct LogExporter: TelemetryExporter {
    public let exporterID = "log"
    public var minimumEventLevel: TelemetryEvent.Level
    private let logger: Logger

    public init(
        subsystem: String = Bundle.main.bundleIdentifier ?? "TelemetryHub",
        category: String = "telemetry",
        minimumEventLevel: TelemetryEvent.Level = .debug
    ) {
        self.logger = Logger(subsystem: subsystem, category: category)
        self.minimumEventLevel = minimumEventLevel
    }

    public func export(_ signals: [TelemetrySignal]) async {
        for signal in signals {
            switch signal {
            case .metric(let metric):
                let tags = Self.format(tags: metric.tags)
                logger.debug("\(metric.name, privacy: .public)=\(metric.value, privacy: .public) \(metric.unit.rawValue, privacy: .public)\(tags, privacy: .public)")
            case .event(let event):
                guard event.level >= minimumEventLevel else { continue }
                let tags = Self.format(tags: event.tags)
                let message = event.message.map { " \($0)" } ?? ""
                switch event.level {
                case .debug:
                    logger.debug("\(event.name, privacy: .public)\(message, privacy: .public)\(tags, privacy: .public)")
                case .info:
                    logger.info("\(event.name, privacy: .public)\(message, privacy: .public)\(tags, privacy: .public)")
                case .warning:
                    logger.warning("\(event.name, privacy: .public)\(message, privacy: .public)\(tags, privacy: .public)")
                case .error:
                    logger.error("\(event.name, privacy: .public)\(message, privacy: .public)\(tags, privacy: .public)")
                }
            case .trace(let trace):
                let tags = Self.format(tags: trace.tags)
                let millis = trace.duration * 1000
                let status = trace.status.isError ? "error" : "ok"
                logger.debug("\(trace.name, privacy: .public) \(millis, format: .fixed(precision: 1), privacy: .public)ms \(status, privacy: .public)\(tags, privacy: .public)")
            }
        }
    }

    private static func format(tags: [String: String]) -> String {
        guard !tags.isEmpty else { return "" }
        return " [" + tags.sorted(by: { $0.key < $1.key }).map { "\($0.key)=\($0.value)" }.joined(separator: " ") + "]"
    }
}

public final class InMemoryExporter: TelemetryExporter, @unchecked Sendable {
    public let exporterID = "in-memory"
    private let lock = OSAllocatedUnfairLock(initialState: [TelemetrySignal]())

    public init() {}

    public var signals: [TelemetrySignal] {
        lock.withLock { $0 }
    }

    public var metrics: [TelemetryMetric] {
        signals.compactMap {
            if case .metric(let metric) = $0 { return metric }
            return nil
        }
    }

    public var events: [TelemetryEvent] {
        signals.compactMap {
            if case .event(let event) = $0 { return event }
            return nil
        }
    }

    public var traces: [TelemetryTrace] {
        signals.compactMap {
            if case .trace(let trace) = $0 { return trace }
            return nil
        }
    }

    public func export(_ signals: [TelemetrySignal]) async {
        lock.withLock { $0.append(contentsOf: signals) }
    }

    public func removeAll() {
        lock.withLock { $0.removeAll() }
    }
}
