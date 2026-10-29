import AppKit

/// Brings another app forward from Orbit, which is normally not the active app (its menu bar panel and the
/// Dock preview never activate it). Under macOS 14's cooperative activation a background app's plain
/// `activate` may be ignored, so Orbit first yields its activation to the target
/// (`NSApp.yieldActivation(to:)`) and then asks the target to activate from Orbit
/// (`activate(from:options:)`), falling back to the plain call if that is refused.
@MainActor
enum AppActivation {
    static func activate(_ app: NSRunningApplication, allWindows: Bool = false) {
        guard !app.isTerminated else { return }
        if app.isHidden { app.unhide() }
        let options: NSApplication.ActivationOptions = allWindows ? [.activateAllWindows] : []
        NSApp.yieldActivation(to: app)
        if !app.activate(from: NSRunningApplication.current, options: options) {
            app.activate(options: options)
        }
    }
}
