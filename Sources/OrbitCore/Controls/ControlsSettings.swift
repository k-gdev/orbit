import Combine
import Foundation

/// Controls' persisted settings (keys prefixed `controls.`). The mic mute shortcut is shared with Sound
/// and lives in `MicMuteSettings`.
public final class ControlsSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let keepDisplayAwake = "controls.keepDisplayAwake"
        static let customDuration = "controls.customDuration"
        static let lastMode = "controls.lastMode"
        static let grabTextShortcut = "controls.grabTextShortcut"
        static let focusShortcutName = "controls.focusShortcutName"
        static let visibleToggles = "controls.visibleToggles"
        static let restoreBook = "controls.restoreBook"
    }

    public static let defaultCustomDuration: TimeInterval = 45 * 60
    /// The custom duration's range: 1 minute to 24 hours.
    public static let customDurationRange: ClosedRange<TimeInterval> = 60...(24 * 3600)

    /// Keep Awake also keeps the display awake (`PreventUserIdleDisplaySleep`). Default off.
    @Published public var keepDisplayAwake: Bool {
        didSet { defaults.set(keepDisplayAwake, forKey: Key.keepDisplayAwake) }
    }

    /// The "Custom" duration in the Keep Awake menu, in seconds (default 45 min, clamped to 1 min…24 h).
    @Published public var customDuration: TimeInterval {
        didSet {
            let clamped = Self.clampDuration(customDuration)
            if clamped != customDuration { customDuration = clamped }
            defaults.set(clamped, forKey: Key.customDuration)
        }
    }

    /// The mode Keep Awake last started with (the switch resumes it when it still makes sense).
    @Published public var lastMode: KeepAwakeMode? {
        didSet { store(lastMode, forKey: Key.lastMode) }
    }

    /// Grab Text's global shortcut (default ⇧⌘2).
    @Published public var grabTextShortcut: KeyCombo {
        didSet { store(grabTextShortcut, forKey: Key.grabTextShortcut) }
    }

    /// The name of the user's Shortcut that sets Focus / Do Not Disturb, or nil when none is chosen.
    @Published public var focusShortcutName: String? {
        didSet {
            let clean = Self.cleanName(focusShortcutName)
            if clean != focusShortcutName { focusShortcutName = clean }
            if let clean { defaults.set(clean, forKey: Key.focusShortcutName) } else { defaults.removeObject(forKey: Key.focusShortcutName) }
        }
    }

    /// Which Quick Toggles the grid shows, always in grid order (`QuickToggleID.allCases`).
    @Published public var visibleToggles: [QuickToggleID] {
        didSet {
            let ordered = Self.ordered(visibleToggles)
            if ordered != visibleToggles { visibleToggles = ordered }
            defaults.set(ordered.map(\.rawValue), forKey: Key.visibleToggles)
        }
    }

    /// What each toggle held before Orbit turned it on (see `QuickToggleRestoreBook`).
    @Published public var restoreBook: QuickToggleRestoreBook {
        didSet { store(restoreBook, forKey: Key.restoreBook) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func decode<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(T.self, from: $0) }
        }
        keepDisplayAwake = defaults.object(forKey: Key.keepDisplayAwake) as? Bool ?? false
        customDuration = Self.clampDuration(defaults.object(forKey: Key.customDuration) as? Double ?? Self.defaultCustomDuration)
        lastMode = decode(KeepAwakeMode.self, Key.lastMode)
        grabTextShortcut = decode(KeyCombo.self, Key.grabTextShortcut) ?? .grabTextDefault
        focusShortcutName = Self.cleanName(defaults.string(forKey: Key.focusShortcutName))
        if let raw = defaults.stringArray(forKey: Key.visibleToggles) {
            visibleToggles = Self.ordered(raw.compactMap(QuickToggleID.init(rawValue:)))
        } else {
            visibleToggles = QuickToggleID.allCases
        }
        restoreBook = decode(QuickToggleRestoreBook.self, Key.restoreBook) ?? QuickToggleRestoreBook()
    }

    private func store<T: Encodable>(_ value: T?, forKey key: String) {
        if let value, let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func clampDuration(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds, customDurationRange.lowerBound), customDurationRange.upperBound)
    }

    private static func cleanName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func ordered(_ toggles: [QuickToggleID]) -> [QuickToggleID] {
        QuickToggleID.allCases.filter(toggles.contains)
    }
}
