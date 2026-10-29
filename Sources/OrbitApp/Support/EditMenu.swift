import AppKit
import OrbitCore

/// Orbit's hidden main menu, and the text-editing keys for its non-activating panels.
///
/// Orbit is an accessory app without a nib, so it has no main menu unless it makes one, and in a text view
/// ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z only work through Edit menu items. `install()` sets a main menu that is never
/// drawn (accessory apps have no menu bar): Quit Orbit and an Edit menu (`TextEditingShortcut`). The menu bar
/// panel and the clipboard popup take typing while another app stays the active one, when AppKit may not
/// look at Orbit's main menu, so they also call `perform(_:in:)` from `performKeyEquivalent(with:)`.
@MainActor
enum EditMenu {
    static func install() {
        let main = NSMenu(title: "Main")

        let appMenu = NSMenu(title: "Orbit")
        appMenu.addItem(withTitle: "Quit Orbit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        for shortcut in TextEditingShortcut.allCases {
            if shortcut == .cut { edit.addItem(.separator()) }
            let item = NSMenuItem(title: shortcut.menuTitle, action: Selector(shortcut.actionName), keyEquivalent: shortcut.keyEquivalent)
            item.keyEquivalentModifierMask = shortcut.usesShift ? [.command, .shift] : [.command]
            edit.addItem(item)
        }
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// When a text view in `window` is being edited and `event` is ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z or ⇧⌘Z, sends that
    /// Edit action down the responder chain and returns whether something handled it. Any other key or
    /// first responder returns false, and the window goes on as usual (SwiftUI shortcuts such as ⌘Q, ⌘,).
    static func perform(_ event: NSEvent, in window: NSWindow) -> Bool {
        guard event.type == .keyDown, window.firstResponder is NSText else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard let shortcut = TextEditingShortcut(key: event.charactersIgnoringModifiers ?? "", command: flags.contains(.command),
                                                 shift: flags.contains(.shift), option: flags.contains(.option),
                                                 control: flags.contains(.control)) else { return false }
        let action = Selector(shortcut.actionName)
        // While the panel takes typing it is the app's key window, so the chain starts at its text view.
        // Should AppKit not count it as key, start at that text view explicitly (the chain still ends at
        // the window, which handles undo: and redo:).
        if NSApp.keyWindow === window { return NSApp.sendAction(action, to: nil, from: window) }
        return window.firstResponder?.tryToPerform(action, with: window) ?? false
    }
}
