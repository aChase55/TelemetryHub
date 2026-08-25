import Foundation

public struct TelemetryConfiguration: Sendable {
    public var isEnabled: Bool
    public var flushInterval: TimeInterval
    public var maxBufferedSignals: Int
    public var storeHistoryLimit: Int
    public var storeEventLimit: Int
    public var storeTraceLimit: Int
    public var globalTags: [String: String]

    public init(
        isEnabled: Bool = true,
        flushInterval: TimeInterval = 1.0,
        maxBufferedSignals: Int = 10_000,
        storeHistoryLimit: Int = 600,
        storeEventLimit: Int = 200,
        storeTraceLimit: Int = 200,
        globalTags: [String: String] = [:]
    ) {
        self.isEnabled = isEnabled
        self.flushInterval = flushInterval
        self.maxBufferedSignals = maxBufferedSignals
        self.storeHistoryLimit = storeHistoryLimit
        self.storeEventLimit = storeEventLimit
        self.storeTraceLimit = storeTraceLimit
        self.globalTags = globalTags
    }
}
