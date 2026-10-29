import Foundation

/// Something the user can do with one history entry, from its right-click menu, a hover button or a
/// popup key. Doing it is the app's job; this only says what is on offer.
public enum ClipboardEntryAction: Equatable, Sendable {
    case copy
    /// Opens a file entry's files with their default apps.
    case open
    case showInFinder
    /// Opens an image entry (as a temporary PNG) in Preview.
    case openInPreview
    case pin
    case unpin
    case remove

    public var title: String {
        switch self {
        case .copy: "Copy"
        case .open: "Open"
        case .showInFinder: "Show in Finder"
        case .openInPreview: "Open in Preview"
        case .pin: "Pin"
        case .unpin: "Unpin"
        case .remove: "Remove"
        }
    }
}

/// One line of an entry's right-click menu.
public enum ClipboardMenuEntry: Equatable, Sendable {
    case action(ClipboardEntryAction, enabled: Bool)
    case separator
}

/// How many of a files entry's files are still where they were copied from. The history stores
/// references, not copies, so a file can be moved or deleted afterwards.
public struct ClipboardFileStatus: Equatable, Sendable {
    public var present: [String]
    public var missing: [String]

    /// Looks each path up with `exists` (the real file system by default).
    public init(paths: [String], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        let there = paths.filter(exists)
        present = there
        missing = paths.filter { !there.contains($0) }
    }

    /// Whether at least one file is still there, which is what opening, revealing and copying need.
    public var isUsable: Bool { !present.isEmpty }

    /// What a row's meta line adds: "Missing" when nothing is left (or the list could not be read),
    /// "2 missing" when only some are gone, nil when all are there.
    public var metaLabel: String? {
        if present.isEmpty { return "Missing" }
        return missing.isEmpty ? nil : "\(missing.count) missing"
    }
}

/// The right-click menu of an entry, in the menu bar tab and in the popup alike.
public enum ClipboardEntryMenu {
    /// Copy first, then what suits the kind (files: Open, Show in Finder; images: Open in Preview), then
    /// Pin or Unpin (not for a copied password), a divider and Remove. `files` is what is known about a
    /// files entry's files; with none of them left their actions are disabled, and nil (not checked)
    /// leaves them enabled.
    public static func entries(for item: ClipboardItem, files: ClipboardFileStatus? = nil) -> [ClipboardMenuEntry] {
        let available = files?.isUsable ?? true
        var entries: [ClipboardMenuEntry] = []
        if item.concealed {
            entries.append(.action(.copy, enabled: true))
        } else {
            switch item.kind {
            case .files:
                entries += [.action(.copy, enabled: available), .action(.open, enabled: available),
                            .action(.showInFinder, enabled: available)]
            case .image:
                entries += [.action(.copy, enabled: true), .action(.openInPreview, enabled: true)]
            case .text, .richText:
                entries.append(.action(.copy, enabled: true))
            }
            entries.append(.action(item.pinned ? .unpin : .pin, enabled: true))
        }
        entries.append(.separator)
        entries.append(.action(.remove, enabled: true))
        return entries
    }
}

/// The keys the clipboard popup itself handles on top of ↑ ↓ Return Esc: ⌘C copies the selected entry
/// without pasting, ⌘O opens it, ⌘R shows its files in Finder.
public enum ClipboardPopupShortcut: Equatable, Sendable {
    case copy, open, showInFinder

    /// The shortcut a key press stands for, if any. `key` is the key's character without modifiers (Caps
    /// Lock may make it a capital). Only the bare Command key counts.
    public init?(key: String, command: Bool, shift: Bool, option: Bool, control: Bool) {
        guard command, !shift, !option, !control else { return nil }
        switch key.lowercased() {
        case "c": self = .copy
        case "o": self = .open
        case "r": self = .showInFinder
        default: return nil
        }
    }

    /// What this key does to `item`, or nil when it means nothing for that entry (⌘O on text).
    public func action(for item: ClipboardItem) -> ClipboardEntryAction? {
        switch self {
        case .copy:
            return .copy
        case .open:
            guard !item.concealed else { return nil }
            switch item.kind {
            case .files: return .open
            case .image: return .openInPreview
            case .text, .richText: return nil
            }
        case .showInFinder:
            return item.kind == .files && !item.concealed ? .showInFinder : nil
        }
    }

    /// ⌘C is also the search field's own Copy: while it has selected text, the field keeps the key.
    public func yieldsToTextField(selectionLength: Int) -> Bool {
        self == .copy && selectionLength > 0
    }

    /// The popup's footer: the keys that work now. `verb` is what Return does ("paste", or "copy" when
    /// Orbit cannot press ⌘V), and ⌘C is left out when it would say the same.
    public static func hint(verb: String, for item: ClipboardItem?) -> String {
        var parts = ["↑↓ select", "↩ \(verb)"]
        if verb != "copy" { parts.append("⌘C copy") }
        if let item {
            if ClipboardPopupShortcut.open.action(for: item) != nil { parts.append("⌘O open") }
            if ClipboardPopupShortcut.showInFinder.action(for: item) != nil { parts.append("⌘R reveal") }
        }
        parts.append("esc close")
        return parts.joined(separator: "    ")
    }
}
