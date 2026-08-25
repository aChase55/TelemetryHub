import Foundation
import TelemetryHub

enum ValueFormatting {
    static func format(_ value: Double, unit: TelemetryUnit) -> String {
        switch unit {
        case .none:
            return number(value)
        case .count:
            return number(value)
        case .bytes:
            return byteCount(value)
        case .bytesPerSecond:
            return byteCount(value) + "/s"
        case .bitsPerSecond:
            return bitrate(value)
        case .milliseconds:
            return number(value) + " ms"
        case .seconds:
            return number(value) + " s"
        case .percent:
            return number(value) + "%"
        case .framesPerSecond:
            return number(value) + " fps"
        case .pixels:
            return number(value) + " px"
        case .celsius:
            return number(value) + " °C"
        }
    }

    static func bitrate(_ bitsPerSecond: Double) -> String {
        switch bitsPerSecond {
        case ..<1_000:
            return number(bitsPerSecond) + " bps"
        case ..<1_000_000:
            return number(bitsPerSecond / 1_000) + " Kbps"
        case ..<1_000_000_000:
            return number(bitsPerSecond / 1_000_000) + " Mbps"
        default:
            return number(bitsPerSecond / 1_000_000_000) + " Gbps"
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return number(seconds * 1000) + " ms"
        }
        return number(seconds) + " s"
    }

    private static func byteCount(_ value: Double) -> String {
        guard let intValue = Int64(exactly: value.rounded(.towardZero)) else {
            return number(value)
        }
        return intValue.formatted(.byteCount(style: .binary))
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1_000_000 {
            return String(Int(value))
        }
        return value.formatted(.number.precision(.fractionLength(0...2)))
    }
}
