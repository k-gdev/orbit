import Combine
import Foundation

/// One app's settings in the Sound mixer: its volume (0…150 %, past 100 is boost), whether it is muted,
/// and the output device it plays on (`outputUID`, nil = Same as Output).
public struct AppAudioPreference: Codable, Equatable, Sendable {
    public static let volumeRange: ClosedRange<Double> = 0...150

    private var storedVolume: Double
    public var muted: Bool
    /// The UID of the output device this app plays on, or nil to follow the system output.
    public var outputUID: String?

    /// The volume in percent, clamped to 0…150 (NaN reads as 100).
    public var volume: Double {
        get { storedVolume }
        set { storedVolume = Self.clamp(newValue) }
    }

    public init(volume: Double = 100, muted: Bool = false, outputUID: String? = nil) {
        storedVolume = Self.clamp(volume)
        self.muted = muted
        self.outputUID = outputUID
    }

    /// 100 %, unmuted, Same as Output: the state that needs no process tap.
    public static let unity = AppAudioPreference()

    /// Whether this is the untouched state (`unity`).
    public var isDefault: Bool { self == .unity }

    private static func clamp(_ value: Double) -> Double {
        guard !value.isNaN else { return 100 }
        return min(max(value, volumeRange.lowerBound), volumeRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey {
        case volume, muted, outputUID
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(volume: try c.decodeIfPresent(Double.self, forKey: .volume) ?? 100,
                  muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  outputUID: try c.decodeIfPresent(String.self, forKey: .outputUID))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(volume, forKey: .volume)
        try c.encode(muted, forKey: .muted)
        try c.encodeIfPresent(outputUID, forKey: .outputUID)
    }
}

/// The Sound feature's persisted settings (keys prefixed `sound.`). The mic mute shortcut is shared with
/// Controls and lives in `MicMuteSettings`.
public final class SoundSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let pinnedBundleIDs = "sound.pinnedBundleIDs"
        static let appStates = "sound.appStates"
        static let rememberAppStates = "sound.rememberAppStates"
        static let preferredMicUID = "sound.preferredMicUID"
        static let keepPreferredMic = "sound.keepPreferredMic"
        static let showAllApps = "sound.showAllApps"
    }

    /// Apps always listed in the panel, in the order they were pinned.
    @Published public var pinnedBundleIDs: [String] {
        didSet { defaults.set(pinnedBundleIDs, forKey: Key.pinnedBundleIDs) }
    }

    /// Bundle ID → that app's volume, mute and output. Only non-default states are kept. Persisted (as
    /// JSON) only while `rememberAppStates` is on.
    @Published public var appStates: [String: AppAudioPreference] {
        didSet { if !deferringSave { saveAppStates() } }
    }

    /// True while `setPreference(_:for:persist: false)` changes the state without writing it.
    private var deferringSave = false

    /// Whether per-app volume, mute and output survive a relaunch (default on). Turning it off removes the
    /// stored copy; the states still apply until Orbit quits.
    @Published public var rememberAppStates: Bool {
        didSet {
            defaults.set(rememberAppStates, forKey: Key.rememberAppStates)
            saveAppStates()
        }
    }

    /// The microphone to keep as the input device (its UID), if any.
    @Published public var preferredMicUID: String? {
        didSet {
            if let preferredMicUID { defaults.set(preferredMicUID, forKey: Key.preferredMicUID) }
            else { defaults.removeObject(forKey: Key.preferredMicUID) }
        }
    }

    /// When macOS switches the input away from `preferredMicUID` while it is connected, switch back
    /// (default off).
    @Published public var keepPreferredMic: Bool {
        didSet { defaults.set(keepPreferredMic, forKey: Key.keepPreferredMic) }
    }

    /// The panel lists every running app with audio, not just the ones playing or pinned.
    @Published public var showAllApps: Bool {
        didSet { defaults.set(showAllApps, forKey: Key.showAllApps) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let remember = defaults.object(forKey: Key.rememberAppStates) as? Bool ?? true
        rememberAppStates = remember
        pinnedBundleIDs = Self.unique(defaults.stringArray(forKey: Key.pinnedBundleIDs) ?? [])
        appStates = remember ? Self.decodeStates(defaults.data(forKey: Key.appStates)) : [:]
        preferredMicUID = defaults.string(forKey: Key.preferredMicUID)
        keepPreferredMic = defaults.object(forKey: Key.keepPreferredMic) as? Bool ?? false
        showAllApps = defaults.object(forKey: Key.showAllApps) as? Bool ?? false
    }

    /// The app's settings (`unity` when it has none).
    public func preference(for bundleID: String) -> AppAudioPreference {
        appStates[bundleID] ?? .unity
    }

    /// Stores the app's settings; the default state removes its entry. With `persist: false` (each tick of a
    /// volume drag) the change is live (published) but not written to defaults until `persistAppStates()`.
    public func setPreference(_ preference: AppAudioPreference, for bundleID: String, persist: Bool = true) {
        deferringSave = !persist
        defer { deferringSave = false }
        if preference.isDefault {
            if appStates[bundleID] != nil { appStates[bundleID] = nil }
        } else if appStates[bundleID] != preference {
            appStates[bundleID] = preference
        }
    }

    /// Writes the per-app states (when "remember" is on): the end of a volume drag, the panel closing.
    public func persistAppStates() {
        saveAppStates()
    }

    /// Drops every app's settings (they all go back to 100 %, unmuted, Same as Output).
    public func forgetAppStates() {
        appStates = [:]
    }

    public func isPinned(_ bundleID: String) -> Bool { pinnedBundleIDs.contains(bundleID) }

    public func pin(_ bundleID: String) {
        guard !bundleID.isEmpty, !isPinned(bundleID) else { return }
        pinnedBundleIDs.append(bundleID)
    }

    public func unpin(_ bundleID: String) {
        pinnedBundleIDs.removeAll { $0 == bundleID }
    }

    private func saveAppStates() {
        guard rememberAppStates else {
            defaults.removeObject(forKey: Key.appStates)
            return
        }
        if let data = try? JSONEncoder().encode(appStates) { defaults.set(data, forKey: Key.appStates) }
    }

    private static func decodeStates(_ data: Data?) -> [String: AppAudioPreference] {
        guard let data, let states = try? JSONDecoder().decode([String: AppAudioPreference].self, from: data) else { return [:] }
        return states.filter { !$0.value.isDefault }
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
