import Foundation

/// Other apps that drive the same monitors' brightness and resolution. While one runs, both apps send DDC
/// commands and can undo each other, so the Displays tab says so in one line.
public enum DisplayConflicts {
    /// Bundle identifier → app name.
    public static let knownApps: [(bundleID: String, name: String)] = [
        ("pro.betterdisplay.BetterDisplay", "BetterDisplay"),
        ("me.guillaumeb.MonitorControl", "MonitorControl"),
        ("fyi.lunar.Lunar", "Lunar"),
    ]

    /// The hint for the running apps (by bundle identifier), or nil when none of `knownApps` runs.
    public static func hint(runningBundleIDs: [String]) -> String? {
        let running = Set(runningBundleIDs)
        let names = knownApps.filter { running.contains($0.bundleID) }.map(\.name)
        guard let last = names.last else { return nil }
        if names.count == 1 { return "\(last) is running too and may undo changes made here." }
        let list = names.dropLast().joined(separator: ", ") + " and " + last
        return "\(list) are running too and may undo changes made here."
    }
}
