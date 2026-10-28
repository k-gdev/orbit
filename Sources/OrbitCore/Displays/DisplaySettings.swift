import Combine
import Foundation

/// The Displays feature's persisted settings (`displays.*` keys). Per-display values are keyed by the
/// shell's `DisplayIdentity.key(for:)`, which survives reboots and reconnects.
public final class DisplaySettings: ObservableObject {
    private let defaults: UserDefaults

    enum Key {
        static let linkBrightness = "displays.linkBrightness"
        static let maxOverrides = "displays.maxOverrides"
        static let useGammaFallback = "displays.useGammaFallback"
        static let lastSoftwareDim = "displays.lastSoftwareDim"
        static let learnedMaximums = "displays.learnedMaximums"
    }

    /// Moving one display's brightness moves the others proportionally. Off by default.
    @Published public var linkBrightness: Bool {
        didSet { defaults.set(linkBrightness, forKey: Key.linkBrightness) }
    }

    /// "Maximum brightness" overrides from Settings, for monitors that report 100 but accept more. A
    /// display without an entry uses "Auto" (what it reports, or has been seen to reach).
    @Published public var maxOverrides: [String: Int] {
        didSet { defaults.set(maxOverrides, forKey: Key.maxOverrides) }
    }

    /// Dim displays that don't answer DDC with their gamma tables. On by default.
    @Published public var useGammaFallback: Bool {
        didSet { defaults.set(useGammaFallback, forKey: Key.useGammaFallback) }
    }

    /// The software-dimming level (0...100) last chosen for each gamma-dimmed display, re-applied when the
    /// feature starts and after display changes (macOS resets gamma tables then).
    @Published public var lastSoftwareDim: [String: Double] {
        didSet { defaults.set(lastSoftwareDim, forKey: Key.lastSoftwareDim) }
    }

    /// The highest DDC brightness each display has been seen at when that exceeded its reported maximum
    /// (a ThinkVision boosted to 150 from its own menu replies "150 of 100"), so the pill keeps its boost
    /// zone after the brightness is turned down again.
    @Published public var learnedMaximums: [String: Int] {
        didSet { defaults.set(learnedMaximums, forKey: Key.learnedMaximums) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        linkBrightness = defaults.object(forKey: Key.linkBrightness) as? Bool ?? false
        maxOverrides = Self.integers(defaults.dictionary(forKey: Key.maxOverrides))
        useGammaFallback = defaults.object(forKey: Key.useGammaFallback) as? Bool ?? true
        lastSoftwareDim = (defaults.dictionary(forKey: Key.lastSoftwareDim) ?? [:])
            .compactMapValues { ($0 as? NSNumber)?.doubleValue }
        learnedMaximums = Self.integers(defaults.dictionary(forKey: Key.learnedMaximums))
    }

    /// The override for `key`, or nil for "Auto".
    public func maxOverride(for key: String) -> Int? { maxOverrides[key] }

    /// Sets (or with nil clears) the override for `key`. Values outside 1...65535 clear it.
    public func setMaxOverride(_ value: Int?, for key: String) {
        if let value, (1...BrightnessRange.ceiling).contains(value) {
            if maxOverrides[key] != value { maxOverrides[key] = value }
        } else if maxOverrides[key] != nil {
            maxOverrides[key] = nil
        }
    }

    /// Remembers that `key` reported `value` above its reported maximum; keeps the highest seen.
    public func learn(maximum value: Int, reported: Int, for key: String) {
        guard value > reported, value > (learnedMaximums[key] ?? 0) else { return }
        learnedMaximums[key] = min(value, BrightnessRange.ceiling)
    }

    /// Forgets the learned maximum for `key` (Settings → Reset learned range).
    public func forgetLearnedMaximum(for key: String) {
        if learnedMaximums[key] != nil { learnedMaximums[key] = nil }
    }

    private static func integers(_ dictionary: [String: Any]?) -> [String: Int] {
        (dictionary ?? [:]).compactMapValues { ($0 as? NSNumber)?.intValue }
    }
}
