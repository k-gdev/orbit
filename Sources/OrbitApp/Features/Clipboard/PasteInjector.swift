import AppKit
import ApplicationServices
import OrbitCore

/// Pasting into the app that was in front before the popup: bring it back, then press ⌘V for the user.
/// Posting key events needs Accessibility; without it nothing is posted and the caller just copies.
@MainActor
enum PasteInjector {
    /// Whether macOS lets Orbit post key events right now (a plain read, never a prompt).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Whether `app` is the frontmost application right now.
    static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// Makes `app` the frontmost application again and waits (briefly) until it is. The popup is a
    /// non-activating panel, so the app normally never lost the front; this only matters when
    /// something else took it meanwhile. Returns whether `app` really is frontmost at the end: false
    /// when there is no app, it quit, or macOS refused to activate it (activating from an app that is
    /// not itself active may be refused). The caller must not press ⌘V on a false.
    static func bringToFront(_ app: NSRunningApplication?) async -> Bool {
        guard let app, !app.isTerminated else { return false }
        if isFrontmost(app) { return true }
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(0.8)
        while !isFrontmost(app), !app.isTerminated, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !app.isTerminated && isFrontmost(app)
    }

    /// Presses ⌘V (key down, key up) in whatever app is in front. False when Orbit isn't trusted for
    /// Accessibility or the events could not be built.
    @discardableResult
    static func postPaste() -> Bool {
        guard isTrusted else { return false }
        let vKey: CGKeyCode = 9
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgSessionEventTap)
        up.post(tap: .cgSessionEventTap)
        return true
    }
}
