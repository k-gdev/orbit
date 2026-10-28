import Foundation

/// The Clipboard feature's hidden command-line modes, behind the single hook in `main.swift`:
/// `--check-clipboard` (`ClipboardCheck`) and `--snapshot-clipboard-popup` (`ClipboardPopupSnapshot`).
enum ClipboardDebug {
    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        ClipboardCheck.runIfRequested(arguments)
        ClipboardPopupSnapshot.runIfRequested(arguments)
    }
}
