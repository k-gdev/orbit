import Foundation

/// One button in the Controls tab's Quick Toggles grid (spec §8.3).
public enum QuickToggleID: String, CaseIterable, Codable, Sendable {
    case darkMode, hideDesktopIcons, showHiddenFiles, nightShift, doNotDisturb, ejectDrives, micMute

    /// The button's name, describing what "on" means.
    public var title: String {
        switch self {
        case .darkMode: "Dark Mode"
        case .hideDesktopIcons: "Hide Desktop"
        case .showHiddenFiles: "Hidden Files"
        case .nightShift: "Night Shift"
        case .doNotDisturb: "Do Not Disturb"
        case .ejectDrives: "Eject Drives"
        case .micMute: "Mute Mic"
        }
    }

    /// The SF Symbol on the button.
    public var symbol: String {
        switch self {
        case .darkMode: "circle.lefthalf.filled"
        case .hideDesktopIcons: "menubar.dock.rectangle"
        case .showHiddenFiles: "eye"
        case .nightShift: "sun.horizon.fill"
        case .doNotDisturb: "moon.fill"
        case .ejectDrives: "eject.fill"
        case .micMute: "mic.slash.fill"
        }
    }

    /// What the toggle does, in a few words (Settings → visible toggles).
    public var summary: String {
        switch self {
        case .darkMode: "Switch the system appearance between light and dark"
        case .hideDesktopIcons: "Hide the files on the desktop (restarts Finder)"
        case .showHiddenFiles: "Show hidden files in Finder (restarts Finder)"
        case .nightShift: "Warmer colours on every display"
        case .doNotDisturb: "Runs a Shortcut you choose that sets Focus"
        case .ejectDrives: "Eject external drives and disk images, after you confirm"
        case .micMute: "The same mic mute as the Sound tab and its shortcut"
        }
    }

    /// Buttons that run something instead of showing an on/off state: Do Not Disturb (macOS gives no
    /// way to read Focus, so it runs the user's Shortcut) and Eject.
    public var isAction: Bool { self == .doNotDisturb || self == .ejectDrives }

    /// Toggles that only take effect after Finder restarts (Orbit restarts it, and says so).
    public var restartsFinder: Bool { self == .hideDesktopIcons || self == .showHiddenFiles }

    /// Whether a stored value means the toggle is on.
    public func isOn(_ value: PreferenceValue) -> Bool {
        switch self {
        case .hideDesktopIcons: value == .bool(false)   // CreateDesktop = false; unset means icons show
        default: value == .bool(true)
        }
    }

    /// The value Orbit writes to turn the toggle on.
    var onValue: PreferenceValue {
        self == .hideDesktopIcons ? .bool(false) : .bool(true)
    }

    /// The value Orbit writes to turn the toggle off when it has no record of what was there before:
    /// Finder keys go back to unset (Finder's default), switches to false.
    var plainOffValue: PreferenceValue {
        restartsFinder ? .absent : .bool(false)
    }
}

/// A preference as Orbit reads and writes it: unset, or a boolean.
public enum PreferenceValue: Codable, Equatable, Hashable, Sendable {
    case absent
    case bool(Bool)

    /// Reads a value from `CFPreferences`: booleans and numbers as booleans, strings like `defaults`
    /// writes them ("YES", "TRUE", "1" → true), anything else as unset.
    public static func parse(_ raw: Any?) -> PreferenceValue {
        switch raw {
        case nil: return .absent
        case let text as String: return .bool(["yes", "true", "1", "on"].contains(text.lowercased()))
        case let number as NSNumber: return .bool(number.boolValue)
        case let flag as Bool: return .bool(flag)
        default: return .absent
        }
    }
}

/// What a toggle held before Orbit turned it on, and what Orbit set, so turning it off restores exactly
/// the earlier state (for example removing Finder's `CreateDesktop` key rather than writing `true`).
public struct QuickToggleRestore: Codable, Equatable, Sendable {
    public var prior: PreferenceValue
    public var applied: PreferenceValue

    public init(prior: PreferenceValue, applied: PreferenceValue) {
        self.prior = prior
        self.applied = applied
    }

    /// The value to put back, or nil when the setting no longer holds what Orbit set (something else
    /// changed it since, so the record is stale).
    public func restoreValue(current: PreferenceValue) -> PreferenceValue? {
        current == applied ? prior : nil
    }
}

/// Every toggle's restore record, persisted in `ControlsSettings` so it survives a relaunch. Quick
/// toggles are system settings the user chose: they stay as set when Orbit quits, and turning one off
/// (now or after a relaunch) restores what was there before.
public struct QuickToggleRestoreBook: Codable, Equatable, Sendable {
    public private(set) var records: [QuickToggleID: QuickToggleRestore] = [:]

    public init() {}

    /// Orbit is turning `id` on: returns the value to write, and remembers what was there unless it was
    /// already on (then nothing is recorded and nothing changes) or Orbit already turned it on.
    public mutating func turnOn(_ id: QuickToggleID, current: PreferenceValue) -> PreferenceValue {
        if let record = records[id], record.applied == current { return current }
        guard !id.isOn(current) else {
            records[id] = nil
            return current
        }
        records[id] = QuickToggleRestore(prior: current, applied: id.onValue)
        return id.onValue
    }

    /// Orbit is turning `id` off: returns exactly what was there before Orbit turned it on when the
    /// setting still holds Orbit's value, otherwise the toggle's plain off value. Drops the record.
    public mutating func turnOff(_ id: QuickToggleID, current: PreferenceValue) -> PreferenceValue {
        if let record = records.removeValue(forKey: id), let prior = record.restoreValue(current: current), !id.isOn(prior) {
            return prior
        }
        return id.plainOffValue
    }
}
