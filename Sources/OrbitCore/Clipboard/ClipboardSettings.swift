import Combine
import Foundation

/// The clipboard history's persisted settings (keys prefixed `clipboard.`). Numbers are kept inside
/// sensible ranges: a value outside one is pulled to its edge, and what was pulled is what is stored.
public final class ClipboardSettings: ObservableObject {
    public static let maxItemsRange = 10...5_000
    public static let maxAgeDaysRange = 1...365
    public static let maxMegabytesRange = 10...5_000
    public static let maxItemMegabytesRange = 1...500

    private let defaults: UserDefaults

    private enum Key {
        static let maxItems = "clipboard.maxItems"
        static let maxAgeDays = "clipboard.maxAgeDays"
        static let maxMegabytes = "clipboard.maxMegabytes"
        static let maxItemMegabytes = "clipboard.maxItemMegabytes"
        static let popupShortcut = "clipboard.popupShortcut"
        static let ignoredBundleIDs = "clipboard.ignoredBundleIDs"
        static let pasteDirectly = "clipboard.pasteDirectly"
    }

    /// How many entries to keep (default 200).
    @Published public var maxItems: Int {
        didSet { let c = settle(maxItems, in: Self.maxItemsRange, key: Key.maxItems); if c != maxItems { maxItems = c } }
    }
    /// How many days to keep an entry (default 30).
    @Published public var maxAgeDays: Int {
        didSet { let c = settle(maxAgeDays, in: Self.maxAgeDaysRange, key: Key.maxAgeDays); if c != maxAgeDays { maxAgeDays = c } }
    }
    /// The most megabytes all stored content may take (default 200).
    @Published public var maxMegabytes: Int {
        didSet { let c = settle(maxMegabytes, in: Self.maxMegabytesRange, key: Key.maxMegabytes); if c != maxMegabytes { maxMegabytes = c } }
    }
    /// A single copy bigger than this many megabytes is not recorded (default 20).
    @Published public var maxItemMegabytes: Int {
        didSet { let c = settle(maxItemMegabytes, in: Self.maxItemMegabytesRange, key: Key.maxItemMegabytes); if c != maxItemMegabytes { maxItemMegabytes = c } }
    }
    /// The global shortcut that opens the popup (default ⇧⌘V). Stored as JSON.
    @Published public var popupShortcut: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(popupShortcut) { defaults.set(data, forKey: Key.popupShortcut) }
        }
    }
    /// Bundle ids of apps whose copies are never recorded.
    @Published public var ignoredBundleIDs: [String] {
        didSet { defaults.set(ignoredBundleIDs, forKey: Key.ignoredBundleIDs) }
    }
    /// Whether choosing an entry in the popup also pastes it (needs Accessibility; otherwise it only copies).
    @Published public var pasteDirectly: Bool {
        didSet { defaults.set(pasteDirectly, forKey: Key.pasteDirectly) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func number(_ key: String, _ fallback: Int, _ range: ClosedRange<Int>) -> Int {
            guard let stored = defaults.object(forKey: key) as? Int else { return fallback }
            return min(max(stored, range.lowerBound), range.upperBound)
        }
        maxItems = number(Key.maxItems, 200, Self.maxItemsRange)
        maxAgeDays = number(Key.maxAgeDays, 30, Self.maxAgeDaysRange)
        maxMegabytes = number(Key.maxMegabytes, 200, Self.maxMegabytesRange)
        maxItemMegabytes = number(Key.maxItemMegabytes, 20, Self.maxItemMegabytesRange)
        popupShortcut = defaults.data(forKey: Key.popupShortcut)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) }
            .flatMap { $0.isUsableAsHotKey ? $0 : nil } ?? .clipboardDefault
        ignoredBundleIDs = defaults.stringArray(forKey: Key.ignoredBundleIDs) ?? []
        pasteDirectly = defaults.object(forKey: Key.pasteDirectly) as? Bool ?? true
    }

    /// The limits these settings describe.
    public var limits: ClipboardLimits {
        ClipboardLimits(maxItems: maxItems, maxAgeDays: maxAgeDays, maxMegabytes: maxMegabytes, maxItemMegabytes: maxItemMegabytes)
    }

    public func isIgnored(_ bundleID: String?) -> Bool {
        bundleID.map(ignoredBundleIDs.contains) ?? false
    }

    /// Adds an app to the ignored list (trimmed; empty and repeated ids are skipped).
    public func addIgnored(_ bundleID: String) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !ignoredBundleIDs.contains(id) else { return }
        ignoredBundleIDs.append(id)
    }

    public func removeIgnored(_ bundleID: String) {
        ignoredBundleIDs.removeAll { $0 == bundleID }
    }

    /// Pulls `value` into `range` and stores what results. The caller assigns the result back only when
    /// it differs, so the observer settles after at most one more pass.
    private func settle(_ value: Int, in range: ClosedRange<Int>, key: String) -> Int {
        let clamped = min(max(value, range.lowerBound), range.upperBound)
        defaults.set(clamped, forKey: key)
        return clamped
    }
}
