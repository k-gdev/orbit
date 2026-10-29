import Foundation

/// One section of the Orbit Suite. `allCases` is the order of the menu bar panel's tabs and of the
/// feature pages in Settings. Raw values are stable: they are persisted (`suite.enabledFeatures`,
/// `suite.lastTab`), prefix each feature's own `UserDefaults` keys (`sound.`, `displays.`, ...) and
/// name its snapshot (`--snapshot-panel sound`).
public enum FeatureID: String, CaseIterable, Codable, Sendable {
    case sound, system, displays, windows, clipboard, shelf, wallpaper, controls

    /// The tab and Settings page name.
    public var title: String {
        switch self {
        case .sound: "Sound"
        case .system: "System"
        case .displays: "Displays"
        case .windows: "Windows"
        case .clipboard: "Clipboard"
        case .shelf: "Shelf"
        case .wallpaper: "Wallpaper"
        case .controls: "Controls"
        }
    }

    /// The SF Symbol shown on the tab, the Settings rail and the Features page.
    public var symbol: String {
        switch self {
        case .sound: "speaker.wave.2"
        case .system: "cpu"
        case .displays: "display"
        case .windows: "macwindow.on.rectangle"
        case .clipboard: "doc.on.clipboard"
        case .shelf: "tray"
        case .wallpaper: "photo.on.rectangle"
        case .controls: "switch.2"
        }
    }

    /// What the feature does, in one line (the Features page).
    public var summary: String {
        switch self {
        case .sound: "Volume and output per app, boost past 100 %, and a shortcut to mute the mic."
        case .system: "CPU, GPU, memory, temperatures, uptime and battery levels at a glance."
        case .displays: "Brightness and resolution for every display, including DDC monitors."
        case .windows: "Window previews over the Dock, and quick control of running apps."
        case .clipboard: "A searchable history of what you copy, with a shortcut to paste it again."
        case .shelf: "A floating shelf that holds files while you move between windows."
        case .wallpaper: "Video wallpapers for each display that keep moving while you work."
        case .controls: "Keep Awake, quick system toggles and Grab Text (copy text from any part of the screen)"
        }
    }

    /// The permissions this feature uses, in the order the Features page lists them. Empty for features
    /// that need none.
    public var permissions: [PermissionUse] {
        switch self {
        case .sound:
            [PermissionUse(permission: .systemAudioRecording, purpose: "Per-app volume, boost and output", requestOnEnable: true)]
        case .windows:
            [PermissionUse(permission: .accessibility, purpose: "Window titles, bring forward, minimise; Dock preview", requestOnEnable: true),
             PermissionUse(permission: .screenRecording, purpose: "Dock preview thumbnails", requestOnEnable: true)]
        case .clipboard:
            [PermissionUse(permission: .accessibility, purpose: "Paste into the frontmost app; without it Orbit only copies", requestOnEnable: false)]
        case .controls:
            [PermissionUse(permission: .screenRecording, purpose: "Grab Text captures the area you select", requestOnEnable: false)]
        case .system, .displays, .shelf, .wallpaper:
            []
        }
    }

    /// Whether the feature is on for a new install (none of these asks for a permission when turned on).
    public var isOnByDefault: Bool {
        switch self {
        case .system, .displays, .shelf, .wallpaper, .controls: true
        case .sound, .windows, .clipboard: false
        }
    }
}
