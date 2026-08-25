import Foundation

public enum TelemetryUnit: String, Sendable, Codable, Hashable {
    case none
    case count
    case bytes
    case bytesPerSecond
    case bitsPerSecond
    case milliseconds
    case seconds
    case percent
    case framesPerSecond
    case pixels
    case celsius
}

public enum MetricKind: String, Sendable, Codable, Hashable {
    case counter
    case gauge
    case histogram
}

public struct TelemetryMetric: Sendable, Codable, Hashable {
    public var name: String
    public var kind: MetricKind
    public var value: Double
    public var unit: TelemetryUnit
    public var tags: [String: String]
    public var timestamp: Date

    public init(
        name: String,
        kind: MetricKind,
        value: Double,
        unit: TelemetryUnit = .none,
        tags: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.name = name
        self.kind = kind
        self.value = value
        self.unit = unit
        self.tags = tags
        self.timestamp = timestamp
    }
}

public struct TelemetryEvent: Sendable, Codable, Hashable {
    public enum Level: String, Sendable, Codable, Comparable, CaseIterable {
        case debug
        case info
        case warning
        case error

        private var rank: Int {
            switch self {
            case .debug: 0
            case .info: 1
            case .warning: 2
            case .error: 3
            }
        }

        public static func < (lhs: Level, rhs: Level) -> Bool {
            lhs.rank < rhs.rank
        }
    }

    public var name: String
    public var message: String?
    public var level: Level
    public var tags: [String: String]
    public var timestamp: Date

    public init(
        name: String,
        message: String? = nil,
        level: Level = .info,
        tags: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.name = name
        self.message = message
        self.level = level
        self.tags = tags
        self.timestamp = timestamp
    }
}

public struct TelemetryTrace: Sendable, Codable, Hashable {
    public enum Kind: String, Sendable, Codable, Hashable {
        case httpRequest
        case grpcCall
        case webSocketSession
        case streamSession
        case custom
    }

    public enum Status: Sendable, Codable, Hashable {
        case ok
        case error(String)

        public var isError: Bool {
            if case .error = self { return true }
            return false
        }
    }

    public var name: String
    public var kind: Kind
    public var start: Date
    public var duration: TimeInterval
    public var status: Status
    public var tags: [String: String]
    public var measurements: [String: Double]

    public init(
        name: String,
        kind: Kind,
        start: Date,
        duration: TimeInterval,
        status: Status = .ok,
        tags: [String: String] = [:],
        measurements: [String: Double] = [:]
    ) {
        self.name = name
        self.kind = kind
        self.start = start
        self.duration = duration
        self.status = status
        self.tags = tags
        self.measurements = measurements
    }
}

public enum TelemetrySignal: Sendable, Codable, Hashable {
    case metric(TelemetryMetric)
    case event(TelemetryEvent)
    case trace(TelemetryTrace)

    public var timestamp: Date {
        switch self {
        case .metric(let metric): metric.timestamp
        case .event(let event): event.timestamp
        case .trace(let trace): trace.start
        }
    }
}
