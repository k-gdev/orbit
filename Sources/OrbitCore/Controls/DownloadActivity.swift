import Foundation

/// Whether ~/Downloads holds a download in progress, judged by the partial files browsers write while
/// downloading. Keep Awake's "While downloading" mode lists the folder (top level only) every
/// `pollInterval` seconds, and only while that mode runs.
public enum DownloadActivity {
    /// Safari (`.download`, a bundle), Chrome/Edge/Arc/Brave (`.crdownload`), Firefox (`.part`), legacy
    /// Edge/IE and download managers (`.partial`), Opera (`.opdownload`).
    public static let partialSuffixes = [".download", ".crdownload", ".part", ".partial", ".opdownload"]

    /// How often the folder is listed while the mode runs.
    public static let pollInterval: TimeInterval = 10

    /// True when any name ends with a partial-download suffix (case-insensitive) and has a name before it.
    public static func isActive(fileNames: [String]) -> Bool {
        fileNames.contains { name in
            let lower = name.lowercased()
            return partialSuffixes.contains { lower.count > $0.count && lower.hasSuffix($0) }
        }
    }
}

/// Smooths over the moment between two downloads when no partial file exists: downloads count as active
/// until `grace` seconds after one was last seen.
public struct DownloadWatch: Sendable {
    public var grace: TimeInterval
    private var lastSeen: Date?

    public init(grace: TimeInterval = 2 * DownloadActivity.pollInterval) {
        self.grace = grace
    }

    /// Feeds one poll; returns whether downloads count as active.
    public mutating func update(active: Bool, now: Date) -> Bool {
        if active {
            lastSeen = now
            return true
        }
        guard let lastSeen else { return false }
        return now.timeIntervalSince(lastSeen) < grace
    }
}
