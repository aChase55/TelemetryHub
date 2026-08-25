public protocol TelemetrySource: AnyObject, Sendable {
    var sourceID: String { get }
    func start(hub: Telemetry)
    func stop()
}
