import Foundation

/// A global keyboard shortcut: one key (a macOS virtual key code, layout-independent ANSI position)
/// plus modifiers. Registered by `HotKeyCenter`, recorded by `KeyComboRecorder`.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var keyCode: UInt16
    public var modifiers: ModifierSet

    public init(keyCode: UInt16, modifiers: ModifierSet) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Sound's mic mute toggle: ⌃⌥M.
    public static let micMuteDefault = KeyCombo(keyCode: 46, modifiers: [.control, .option])
    /// Clipboard's history popup: ⇧⌘V.
    public static let clipboardDefault = KeyCombo(keyCode: 9, modifiers: [.shift, .command])
    /// Controls' Grab Text: ⇧⌘2.
    public static let grabTextDefault = KeyCombo(keyCode: 19, modifiers: [.shift, .command])

    /// e.g. "⌃⌥M": modifiers in Apple's order (⌃⌥⇧⌘), then the key's name.
    public var display: String {
        modifiers.symbols + (Self.keyName(for: keyCode) ?? "Key \(keyCode)")
    }

    /// Whether this makes a sensible global shortcut: a named key with ⌃, ⌥ or ⌘ (⇧ alone would
    /// swallow ordinary typing), or a function key on its own.
    public var isUsableAsHotKey: Bool {
        guard Self.keyName(for: keyCode) != nil else { return false }
        if Self.functionKeys[keyCode] != nil { return true }
        return !modifiers.subtracting(.shift).isEmpty
    }

    /// The printed name of an ANSI key code (letters, digits, punctuation, F1–F12, space, return,
    /// tab, delete, arrows), or nil for keys Orbit doesn't offer as shortcuts.
    public static func keyName(for keyCode: UInt16) -> String? {
        names[keyCode] ?? functionKeys[keyCode]
    }

    private static let functionKeys: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let names: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M",
        45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/", 50: "`",
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫",
        123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

extension ModifierSet {
    /// e.g. "⌃⌥" in the conventional macOS order.
    public var symbols: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option) { s += "⌥" }
        if contains(.shift) { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}
