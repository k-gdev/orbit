import Foundation

/// Whether the open menu bar panel closes because an app became active. Switching apps (⌘-Tab, a Dock
/// click) closes it like a click elsewhere does; Orbit itself activating doesn't (an open panel from
/// Settings… or Open Files…), nor an app activating right after a click in the panel, which is that
/// click's doing (hiding or quitting the frontmost app from the Windows tab makes macOS activate the next).
public enum MenuBarPanelDismissal {
    /// How long after a click in the panel an app activating is taken as the click's doing.
    public static let clickGrace: TimeInterval = 1

    /// `activatedPID` is the app that became active (nil when the notification didn't say).
    public static func closesOnActivation(of activatedPID: Int32?, ownPID: Int32, lastPanelClick: Date?, now: Date) -> Bool {
        if activatedPID == ownPID { return false }
        if let click = lastPanelClick {
            let since = now.timeIntervalSince(click)
            if since >= 0, since <= clickGrace { return false }
        }
        return true
    }
}
