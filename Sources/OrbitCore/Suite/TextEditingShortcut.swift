import Foundation

/// The standard text-editing key equivalents: ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A. Orbit is an accessory app, so it
/// has no visible menu bar; the app installs a hidden Edit menu built from these, and its non-activating
/// panels (which take typing while another app stays active, when the main menu may not be consulted)
/// map the same keys themselves while a text field is being edited. Cases are in Edit-menu order.
public enum TextEditingShortcut: String, Sendable, CaseIterable {
    case undo, redo, cut, copy, paste, selectAll

    /// The shortcut a key press stands for, if any. `key` is the key's character without modifiers (Shift
    /// and Caps Lock may make it a capital). Command is required; Option or Control makes it another
    /// command; Shift only turns ⌘Z into redo.
    public init?(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        guard command, !option, !control else { return nil }
        switch (key.lowercased(), shift) {
        case ("z", false): self = .undo
        case ("z", true): self = .redo
        case ("x", false): self = .cut
        case ("c", false): self = .copy
        case ("v", false): self = .paste
        case ("a", false): self = .selectAll
        default: return nil
        }
    }

    /// The responder-chain action the Edit menu sends (`NSText` / `NSResponder` selectors).
    public var actionName: String {
        switch self {
        case .undo: "undo:"
        case .redo: "redo:"
        case .cut: "cut:"
        case .copy: "copy:"
        case .paste: "paste:"
        case .selectAll: "selectAll:"
        }
    }

    public var menuTitle: String {
        switch self {
        case .undo: "Undo"
        case .redo: "Redo"
        case .cut: "Cut"
        case .copy: "Copy"
        case .paste: "Paste"
        case .selectAll: "Select All"
        }
    }

    /// The menu item's key equivalent (lowercase; Shift is `usesShift`).
    public var keyEquivalent: String {
        switch self {
        case .undo, .redo: "z"
        case .cut: "x"
        case .copy: "c"
        case .paste: "v"
        case .selectAll: "a"
        }
    }

    public var usesShift: Bool { self == .redo }
}
