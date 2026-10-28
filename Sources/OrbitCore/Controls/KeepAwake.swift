import Foundation

// MARK: - Mode

/// How long Keep Awake holds the Mac awake (spec §8.2).
public enum KeepAwakeMode: Codable, Equatable, Hashable, Sendable {
    /// Until the user turns it off.
    case indefinitely
    /// For a fixed time from the start (15 min, 1 h, 2 h, 5 h or the custom duration).
    case duration(TimeInterval)
    /// Until a wall-clock time.
    case until(Date)
    /// While an app (by bundle id) is running; ends when it quits.
    case whileAppRunning(bundleID: String)
    /// While files in ~/Downloads are still downloading (partial-download files present).
    case whileDownloading

    /// The fixed durations offered in the mode menu: 15 min, 1 h, 2 h, 5 h.
    public static let presetDurations: [TimeInterval] = [15 * 60, 3600, 2 * 3600, 5 * 3600]

    /// The menu title for the mode ("Indefinitely", "1 hour", "Until 23:30", "While Xcode runs").
    public func title(appName: String? = nil, timeZone: TimeZone = .current, locale: Locale = .current, now: Date = Date()) -> String {
        switch self {
        case .indefinitely: return "Indefinitely"
        case .duration(let seconds): return KeepAwakeFormat.duration(seconds)
        case .until(let date): return "Until " + KeepAwakeFormat.clock(date, now: now, timeZone: timeZone, locale: locale)
        case .whileAppRunning(let bundleID): return "While \(appName ?? Self.fallbackAppName(for: bundleID)) runs"
        case .whileDownloading: return "While downloading"
        }
    }

    /// A readable stand-in for an app name when only its bundle id is known: the id's last component,
    /// capitalised ("com.apple.dt.Xcode" → "Xcode", "org.mozilla.firefox" → "Firefox").
    public static func fallbackAppName(for bundleID: String) -> String {
        guard let last = bundleID.split(separator: ".").last, !last.isEmpty else { return "the app" }
        return last.prefix(1).uppercased() + last.dropFirst()
    }

    /// What the Keep Awake switch starts with, given the last mode used: that mode when it can simply be
    /// started again (indefinitely, a duration, a time still ahead), otherwise indefinitely. App and
    /// download modes depend on what's running now, so they are only chosen from the menu.
    public static func resumable(_ last: KeepAwakeMode?, now: Date) -> KeepAwakeMode {
        switch last {
        case .duration(let seconds) where seconds > 0: return .duration(seconds)
        case .until(let date) where date > now: return .until(date)
        default: return .indefinitely
        }
    }
}

// MARK: - Session

/// One running Keep Awake: when it started, how long it lasts, and whether the display stays on too.
public struct KeepAwakeSession: Codable, Equatable, Sendable {
    public var startDate: Date
    public var mode: KeepAwakeMode
    public var keepDisplayAwake: Bool
    /// The display name of the app for `.whileAppRunning` (resolved by the app when starting).
    public var appName: String?

    public init(startDate: Date, mode: KeepAwakeMode, keepDisplayAwake: Bool, appName: String? = nil) {
        self.startDate = startDate
        self.mode = mode
        self.keepDisplayAwake = keepDisplayAwake
        self.appName = appName
    }

    /// When a timed session ends; nil for sessions that end on a condition (or never).
    public var deadline: Date? {
        switch mode {
        case .duration(let seconds): startDate.addingTimeInterval(seconds)
        case .until(let date): date
        case .indefinitely, .whileAppRunning, .whileDownloading: nil
        }
    }

    /// Seconds left for a timed session (never negative); nil when it has no deadline.
    public func remaining(now: Date) -> TimeInterval? {
        deadline.map { max(0, $0.timeIntervalSince(now)) }
    }

    /// Whether the session is over: its deadline passed, its app quit, or nothing is downloading.
    public func isExpired(now: Date, appRunning: Bool, downloadsActive: Bool) -> Bool {
        switch mode {
        case .indefinitely: false
        case .duration, .until: now >= (deadline ?? .distantFuture)
        case .whileAppRunning: !appRunning
        case .whileDownloading: !downloadsActive
        }
    }

    /// The tile's status line: "1 h 12 m left", "Until 23:30", "While Xcode runs", "While downloading",
    /// "Indefinitely".
    public func label(now: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        switch mode {
        case .duration: KeepAwakeFormat.remaining(remaining(now: now) ?? 0)
        default: mode.title(appName: appName, timeZone: timeZone, locale: locale, now: now)
        }
    }
}

// MARK: - Formatting

public enum KeepAwakeFormat {
    /// Time left, rounded up to whole minutes: "1 h 12 m left", "2 h left", "15 m left", "1 m left".
    public static func remaining(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((max(0, seconds) / 60).rounded(.up)))
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m) m left" }
        return m == 0 ? "\(h) h left" : "\(h) h \(m) m left"
    }

    /// A duration as words: "15 minutes", "1 hour", "1 hour 30 minutes".
    public static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let h = minutes / 60, m = minutes % 60
        func unit(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        switch (h, m) {
        case (0, _): return unit(m, "minute")
        case (_, 0): return unit(h, "hour")
        default: return unit(h, "hour") + " " + unit(m, "minute")
        }
    }

    /// A wall-clock time in the user's format ("23:30" / "11:30 PM"), with the weekday when it isn't
    /// on the same day as `now` ("Thu 07:00").
    public static func clock(_ date: Date, now: Date, timeZone: TimeZone, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate(calendar.isDate(date, inSameDayAs: now) ? "jmm" : "EEEjmm")
        return formatter.string(from: date)
    }
}
