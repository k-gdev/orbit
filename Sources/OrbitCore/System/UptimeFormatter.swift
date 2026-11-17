import Foundation

/// A long duration in its two largest units: "3 d 4 h", "5 h 12 m", "12 m", "< 1 m". Used for uptime
/// and for battery time remaining.
public enum UptimeFormatter {
    public static func string(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 60 else { return "< 1 m" }
        let minutes = Int(seconds / 60)
        let days = minutes / 1440
        let hours = minutes % 1440 / 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 || minutes >= 60 { return "\(minutes / 60) h \(minutes % 60) m" }
        return "\(minutes) m"
    }
}
