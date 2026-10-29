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

    /// The first macOS that has this permission (and its System Settings pane), or nil when every
    /// supported system does. System Audio Recording arrived with process taps in 14.2.
    public var minimumSystemVersion: OperatingSystemVersion? {
        switch self {
        case .systemAudioRecording: OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        case .accessibility, .screenRecording: nil
        }
    }

    /// Whether the permission exists on `version` (pass `ProcessInfo.processInfo.operatingSystemVersion`).
    public func isAvailable(on version: OperatingSystemVersion) -> Bool {
        guard let minimum = minimumSystemVersion else { return true }
        return (version.majorVersion, version.minorVersion, version.patchVersion)
            >= (minimum.majorVersion, minimum.minorVersion, minimum.patchVersion)
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
