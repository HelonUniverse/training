import CoachCore
import Foundation

/// Formats optional device metrics. A missing value reads "not measured",
/// never "0", so an unmeasured number can't pass for a real one.
enum MetricFormat {
    static let missing = "not measured"

    static func memory(peak: Int64?, average: Double?, current: Int64? = nil) -> String {
        guard peak != nil || average != nil || current != nil else { return missing }
        let format = { (bytes: Double?) in bytes.map { String(format: "%.1f MB", $0 / 1_048_576) } ?? "—" }
        var parts = ["peak \(format(peak.map(Double.init)))", "avg \(format(average))"]
        if let current { parts.insert("now \(format(Double(current)))", at: 0) }
        return parts.joined(separator: " · ")
    }

    static func cpu(average: Double?, peak: Double?, current: Double? = nil) -> String {
        guard average != nil || peak != nil || current != nil else { return missing }
        let format = { (value: Double?) in value.map { String(format: "%.0f %%", $0) } ?? "—" }
        var parts = ["avg \(format(average))", "peak \(format(peak))"]
        if let current { parts.insert("now \(format(current))", at: 0) }
        return parts.joined(separator: " · ")
    }

    static func thermal(worst: ThermalState?, current: ThermalState?) -> String {
        guard worst != nil || current != nil else { return missing }
        return "\(worst?.rawValue ?? "—") / \(current?.rawValue ?? "—")"
    }

    static func latency(average: Double?, max: Double?, current: Double? = nil) -> String {
        guard average != nil || max != nil else { return missing }
        let format = { (seconds: Double?) in seconds.map { String(format: "%.1f ms", $0 * 1000) } ?? "—" }
        var parts = ["avg \(format(average))", "max \(format(max))"]
        if let current { parts.insert("now \(format(current))", at: 0) }
        return parts.joined(separator: " · ")
    }
}
