import Foundation
import Sentry
import TelemetryHub

public struct SentryExporterConfiguration: Sendable {
    public var sendMetrics: Bool
    public var sendEventsAsLogs: Bool
    public var sendEventsAsBreadcrumbs: Bool
    public var sendTraces: Bool
    public var minimumEventLevel: TelemetryEvent.Level

    public init(
        sendMetrics: Bool = true,
        sendEventsAsLogs: Bool = true,
        sendEventsAsBreadcrumbs: Bool = false,
        sendTraces: Bool = true,
        minimumEventLevel: TelemetryEvent.Level = .info
    ) {
        self.sendMetrics = sendMetrics
        self.sendEventsAsLogs = sendEventsAsLogs
        self.sendEventsAsBreadcrumbs = sendEventsAsBreadcrumbs
        self.sendTraces = sendTraces
        self.minimumEventLevel = minimumEventLevel
    }
}

public struct SentryExporter: TelemetryExporter {
    public let exporterID = "sentry"
    public let configuration: SentryExporterConfiguration

    public init(configuration: SentryExporterConfiguration = SentryExporterConfiguration()) {
        self.configuration = configuration
    }

    public func export(_ signals: [TelemetrySignal]) async {
        guard SentrySDK.isEnabled else { return }
        for signal in signals {
            switch signal {
            case .metric(let metric):
                if configuration.sendMetrics {
                    export(metric)
                }
            case .event(let event):
                export(event)
            case .trace(let trace):
                if configuration.sendTraces {
                    export(trace)
                }
            }
        }
    }

    public func shutdown() async {
        SentrySDK.flush(timeout: 2.0)
    }

    private func export(_ metric: TelemetryMetric) {
        let attributes = Self.attributes(from: metric.tags)
        switch metric.kind {
        case .counter:
            SentrySDK.metrics.count(
                key: metric.name,
                value: UInt(max(0, metric.value.rounded())),
                attributes: attributes
            )
        case .gauge:
            SentrySDK.metrics.gauge(
                key: metric.name,
                value: metric.value,
                unit: Self.unit(for: metric.unit),
                attributes: attributes
            )
        case .histogram:
            SentrySDK.metrics.distribution(
                key: metric.name,
                value: metric.value,
                unit: Self.unit(for: metric.unit),
                attributes: attributes
            )
        }
    }

    private func export(_ event: TelemetryEvent) {
        guard event.level >= configuration.minimumEventLevel else { return }
        let body = event.message.map { "\(event.name): \($0)" } ?? event.name

        if configuration.sendEventsAsLogs {
            var attributes: [String: Any] = event.tags
            attributes["event.name"] = event.name
            switch event.level {
            case .debug:
                SentrySDK.logger.debug(body, attributes: attributes)
            case .info:
                SentrySDK.logger.info(body, attributes: attributes)
            case .warning:
                SentrySDK.logger.warn(body, attributes: attributes)
            case .error:
                SentrySDK.logger.error(body, attributes: attributes)
            }
        }

        if configuration.sendEventsAsBreadcrumbs {
            let crumb = Breadcrumb(level: Self.level(for: event.level), category: event.name)
            crumb.message = event.message
            crumb.timestamp = event.timestamp
            for (key, value) in event.tags {
                crumb.setData(value: value, key: key)
            }
            SentrySDK.addBreadcrumb(crumb)
        }
    }

    private func export(_ trace: TelemetryTrace) {
        let span = SentrySDK.startTransaction(
            transactionContext: TransactionContext(
                name: trace.name,
                operation: Self.operation(for: trace.kind)
            ),
            bindToScope: false
        )
        span.startTimestamp = trace.start
        for (key, value) in trace.tags {
            span.setTag(value: value, key: key)
        }
        for (name, value) in trace.measurements {
            span.setMeasurement(name: name, value: NSNumber(value: value))
        }
        if case .error(let reason) = trace.status {
            span.setData(value: reason, key: "error.reason")
        }
        span.timestamp = trace.start.addingTimeInterval(trace.duration)
        span.finish(status: trace.status.isError ? .unknownError : .ok)
    }

    private static func attributes(from tags: [String: String]) -> [String: SentryAttributeValue] {
        tags.mapValues { $0 as SentryAttributeValue }
    }

    private static func unit(for unit: TelemetryUnit) -> SentryUnit? {
        switch unit {
        case .none, .count: nil
        case .bytes: .byte
        case .bytesPerSecond: .generic("byte/s")
        case .bitsPerSecond: .generic("bit/s")
        case .milliseconds: .millisecond
        case .seconds: .second
        case .percent: .percent
        case .framesPerSecond: .generic("fps")
        case .pixels: .generic("pixel")
        case .celsius: .generic("celsius")
        }
    }

    private static func level(for level: TelemetryEvent.Level) -> SentryLevel {
        switch level {
        case .debug: .debug
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    private static func operation(for kind: TelemetryTrace.Kind) -> String {
        switch kind {
        case .httpRequest: "http.client"
        case .grpcCall: "grpc.client"
        case .webSocketSession: "websocket"
        case .streamSession: "stream"
        case .custom: "custom"
        }
    }
}
