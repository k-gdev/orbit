import Combine
import Foundation
import OrbitCore

/// Everything the shell hands a feature. One instance, created by `AppDelegate` (or a throwaway one by
/// the snapshot CLI), passed to every feature's `init(context:)`.
@MainActor
final class SuiteContext: ObservableObject {
    /// The app-wide settings (wheel, accent colour, haptics).
    let settings: SettingsStore
    /// Which features are on and the panel's last tab. Turn features on/off through `FeatureRegistry`.
    let suite: SuiteSettings
    /// Where feature settings persist: build `<Feature>Settings(defaults: context.defaults)` on it, with
    /// keys prefixed by the feature id. `.standard` in the app; a throwaway suite in snapshots.
    let defaults: UserDefaults
    /// Global shortcuts (Carbon hot keys; no permission needed).
    let hotKeys: HotKeyCenter
    /// Accessibility, Screen Recording and System Audio Recording status and requests.
    let permissions: PermissionCenter
    /// The ONE mic mute shared by Sound and Controls (state, global shortcut, menu bar badge).
    let micMute: MicMuteService
    /// Small transient messages at the top right of the screen ("Copied 3 lines").
    let toasts: ToastCenter
    /// `~/Library/Application Support/Orbit` in the app (a temp folder in snapshots). Not created until a
    /// feature asks for `directory(for:)`.
    let supportDirectory: URL

    /// Opens the Settings window on a page. Set by `AppDelegate`.
    var openSettings: (SettingsPage) -> Void = { _ in }
    /// Closes the menu bar panel (e.g. before showing a window of the feature's own). Set by `AppDelegate`.
    var closePanel: () -> Void = {}

    /// Ids of the features currently asking for the dot on Orbit's menu bar icon (`setStatusIndicator`).
    @Published private(set) var statusIndicators: Set<String> = []

    init(settings: SettingsStore, suite: SuiteSettings, defaults: UserDefaults, hotKeys: HotKeyCenter,
         permissions: PermissionCenter, micMute: MicMuteService, toasts: ToastCenter, supportDirectory: URL) {
        self.settings = settings
        self.suite = suite
        self.defaults = defaults
        self.hotKeys = hotKeys
        self.permissions = permissions
        self.micMute = micMute
        self.toasts = toasts
        self.supportDirectory = supportDirectory
    }

    /// `~/Library/Application Support/Orbit/<Feature title>/`, created on first use. Call it only when the
    /// feature is about to write there, never from `init`.
    func directory(for feature: FeatureID) throws -> URL {
        let url = supportDirectory.appending(path: feature.title, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Shows (or clears) a small accent dot on Orbit's menu bar icon. `id` names the asker (for example
    /// `"controls.keepAwake"`); the dot shows while any id is active. Clear yours in `stop()`.
    func setStatusIndicator(_ id: String, active: Bool) {
        guard statusIndicators.contains(id) != active else { return }
        if active { statusIndicators.insert(id) } else { statusIndicators.remove(id) }
    }

    /// The app's real Application Support folder for Orbit.
    static var defaultSupportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Orbit", directoryHint: .isDirectory)
    }
}
