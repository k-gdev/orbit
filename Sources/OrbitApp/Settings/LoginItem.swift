import ServiceManagement

/// Launch at login via `SMAppService.mainApp`. Registration only succeeds for the
/// installed .app bundle, so callers surface the thrown error instead of hiding it.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// True when the user must approve Orbit in System Settings → General → Login Items.
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            if service.status != .enabled { try service.register() }
        } else if service.status == .enabled || service.status == .requiresApproval {
            try service.unregister()
        }
    }
}
