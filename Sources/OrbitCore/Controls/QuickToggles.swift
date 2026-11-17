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
    /// Dark Mode only: whether the appearance was on Auto before Orbit turned it on (nil when not
    /// recorded, including records saved before this existed).
    public var priorAutomatic: Bool?

    public init(prior: PreferenceValue, applied: PreferenceValue, priorAutomatic: Bool? = nil) {
        self.prior = prior
        self.applied = applied
        self.priorAutomatic = priorAutomatic
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

    /// Plans turning `id` on or off without changing the book: what to write, whether to change Dark
    /// Mode's Auto setting, and the record to keep afterwards. The app writes, then `commit`s the change
    /// to the book as it is *then*, so two toggles in flight never overwrite each other's record.
    ///
    /// - On: remembers what was there (and, for Dark Mode, whether it was on Auto, which is turned off
    ///   so the choice sticks). Already on, or already turned on by Orbit: nothing to write.
    /// - Off: already off: nothing to write, and any leftover record is dropped. Otherwise exactly what
    ///   was there before Orbit turned it on (Auto included) when the setting still holds Orbit's value,
    ///   else the toggle's plain off value.
    public func change(_ id: QuickToggleID, on: Bool, current: PreferenceValue, automatic: Bool? = nil) -> QuickToggleChange {
        let record = records[id]
        if on {
            if let record, record.applied == current { return QuickToggleChange(write: current, record: record) }
            guard !id.isOn(current) else { return QuickToggleChange(write: current, record: nil) }
            let wasAuto = id == .darkMode ? automatic : nil
            return QuickToggleChange(write: id.onValue, automatic: wasAuto == true ? false : nil,
                                     record: QuickToggleRestore(prior: current, applied: id.onValue, priorAutomatic: wasAuto))
        }
        guard id.isOn(current) else { return QuickToggleChange(write: current, record: nil) }
        if let record, let prior = record.restoreValue(current: current), !id.isOn(prior) {
            return QuickToggleChange(write: prior, automatic: record.priorAutomatic == true ? true : nil, record: nil)
        }
        return QuickToggleChange(write: id.plainOffValue, record: nil)
    }

    /// Stores (or drops) the record a finished change leaves behind.
    public mutating func commit(_ id: QuickToggleID, _ change: QuickToggleChange) {
        records[id] = change.record
    }

    /// `change` + `commit` for turning on; returns the value to write.
    public mutating func turnOn(_ id: QuickToggleID, current: PreferenceValue) -> PreferenceValue {
        let planned = change(id, on: true, current: current)
        commit(id, planned)
        return planned.write
    }

    /// `change` + `commit` for turning off; returns the value to write.
    public mutating func turnOff(_ id: QuickToggleID, current: PreferenceValue) -> PreferenceValue {
        let planned = change(id, on: false, current: current)
        commit(id, planned)
        return planned.write
    }
}

/// One planned toggle change (see `QuickToggleRestoreBook.change`).
public struct QuickToggleChange: Equatable, Sendable {
    /// The value to write (equal to the current value when nothing needs writing).
    public var write: PreferenceValue
    /// Dark Mode only: set the appearance's Auto setting to this (nil: leave it alone).
    public var automatic: Bool?
    /// The record to keep for the toggle once the write succeeded (nil: none).
    public var record: QuickToggleRestore?

    public init(write: PreferenceValue, automatic: Bool? = nil, record: QuickToggleRestore?) {
        self.write = write
        self.automatic = automatic
        self.record = record
    }
}
