import AppKit
import ApplicationServices
import OrbitCore

/// Pasting into the app that was in front before the popup: bring it back, then press ⌘V for the user.
/// Posting key events needs Accessibility; without it nothing is posted and the caller just copies.
@MainActor
enum PasteInjector {
    /// Whether macOS lets Orbit post key events right now (a plain read, never a prompt).
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Makes `app` the frontmost application again and waits (briefly) until it is. The popup is a
    /// non-activating panel, so the app normally never lost the front; this only matters when
    /// something else took it meanwhile.
    static func bringToFront(_ app: NSRunningApplication?) async {
        guard let app, !app.isTerminated else { return }
        let isFront = { NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier }
        if isFront() { return }
        app.activate(options: [])
        let deadline = Date().addingTimeInterval(0.8)
        while !isFront(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
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
