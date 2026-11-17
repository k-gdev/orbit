import Foundation
import Testing
@testable import OrbitCore

/// The text-editing key equivalents Orbit's hidden Edit menu and its non-activating panels share.
@Suite struct TextEditingShortcutTests {
    private func shortcut(_ key: String, shift: Bool = false, option: Bool = false, control: Bool = false,
                          command: Bool = true) -> TextEditingShortcut? {
        TextEditingShortcut(key: key, command: command, shift: shift, option: option, control: control)
    }

    @Test func theStandardKeysMap() {
        #expect(shortcut("x") == .cut)
        #expect(shortcut("c") == .copy)
        #expect(shortcut("v") == .paste)
        #expect(shortcut("a") == .selectAll)
        #expect(shortcut("z") == .undo)
        #expect(shortcut("z", shift: true) == .redo)
        // charactersIgnoringModifiers keeps Shift (⇧⌘Z arrives as "Z"); Caps Lock gives capitals too.
        #expect(shortcut("Z", shift: true) == .redo)
        #expect(shortcut("C") == .copy)
    }

    @Test func otherCombinationsAreLeftAlone() {
        #expect(shortcut("c", command: false) == nil)            // plain typing
        #expect(shortcut("c", shift: true) == nil)               // ⇧⌘C is something else
        #expect(shortcut("v", option: true) == nil)              // ⌥⌘V (move) is not paste
        #expect(shortcut("v", shift: true, option: true) == nil) // ⌥⇧⌘V (paste and match style)
        #expect(shortcut("a", control: true) == nil)
        #expect(shortcut("z", option: true) == nil)
        #expect(shortcut("q") == nil)                            // the panel's own ⌘Q
        #expect(shortcut(",") == nil)                            // and ⌘,
        #expect(shortcut("") == nil)
        #expect(shortcut("cv") == nil)
    }

    @Test func actionsAndMenuItemsAreTheStandardOnes() {
        #expect(TextEditingShortcut.allCases.map(\.actionName) == ["undo:", "redo:", "cut:", "copy:", "paste:", "selectAll:"])
        #expect(TextEditingShortcut.allCases.map(\.menuTitle) == ["Undo", "Redo", "Cut", "Copy", "Paste", "Select All"])
        #expect(TextEditingShortcut.allCases.map(\.keyEquivalent) == ["z", "z", "x", "c", "v", "a"])
        #expect(TextEditingShortcut.allCases.filter(\.usesShift) == [.redo])
        // Every menu item maps back to itself.
        for item in TextEditingShortcut.allCases {
            #expect(shortcut(item.keyEquivalent, shift: item.usesShift) == item)
        }
    }
}
