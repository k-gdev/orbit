import Foundation

/// A macOS privacy permission some suite feature needs. Full Disk Access (the wheel's) lives in
/// `FullDiskAccess`; these are the suite's own.
public enum SuitePermission: String, CaseIterable, Sendable {
    case systemAudioRecording, accessibility, screenRecording

    /// The name System Settings uses for it.
    public var title: String {
        switch self {
        case .systemAudioRecording: "System Audio Recording"
        case .accessibility: "Accessibility"
        case .screenRecording: "Screen Recording"
        }
    }

    /// Opens System Settings at Privacy & Security on this permission's list.
    public var settingsURL: URL {
        let anchor = switch self {
        case .systemAudioRecording: "Privacy_AudioCapture"
        case .accessibility: "Privacy_Accessibility"
        case .screenRecording: "Privacy_ScreenCapture"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }
}

/// How one feature uses one permission.
public struct PermissionUse: Sendable, Equatable {
    public var permission: SuitePermission
    /// What the permission is for in this feature, in a few words (the Features page).
    public var purpose: String
    /// Whether turning the feature on asks for the permission straight away. When false the feature
    /// works without it and only offers it from Settings.
    public var requestOnEnable: Bool

    public init(permission: SuitePermission, purpose: String, requestOnEnable: Bool) {
        self.permission = permission
        self.purpose = purpose
        self.requestOnEnable = requestOnEnable
    }
}
