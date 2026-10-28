import Foundation

/// The clipboard history as a plain value: newest entry first. It knows nothing about files or the
/// pasteboard; the app's model feeds it captures and persists it through `ClipboardStore`.
public struct ClipboardHistory: Equatable, Sendable {
    /// Newest first (the order they are stored in). Pinned entries are not moved; use `displayItems`
    /// for the order a list shows.
    public private(set) var items: [ClipboardItem]

    public init(items: [ClipboardItem] = []) {
        self.items = items
    }

    public var count: Int { items.count }
    public var isEmpty: Bool { items.isEmpty }

    /// The combined size of every entry's stored content.
    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    /// What `add(_:)` did.
    public enum AddResult: Equatable, Sendable {
        case inserted
        /// The same content was already in the history, so that entry moved to the top instead.
        /// `unusedPayload` is the incoming item's blob file when it differs from the kept entry's:
        /// nothing refers to it any more, so the caller should delete it.
        case movedToTop(unusedPayload: String?)
    }

    /// Puts `item` on top. When an entry with the same content hash already exists, that entry is kept
    /// (same id, same blob, same pin) and moves to the top with the new item's date and source.
    @discardableResult
    public mutating func add(_ item: ClipboardItem) -> AddResult {
        guard let index = items.firstIndex(where: { $0.contentHash == item.contentHash }) else {
            items.insert(item, at: 0)
            return .inserted
        }
        var kept = items.remove(at: index)
        kept.date = item.date
        kept.sourceBundleID = item.sourceBundleID
        kept.sourceName = item.sourceName
        items.insert(kept, at: 0)
        let unused = item.payloadFile != kept.payloadFile ? item.payloadFile : nil
        return .movedToTop(unusedPayload: unused)
    }

    public func item(id: UUID) -> ClipboardItem? {
        items.first { $0.id == id }
    }

    public func contains(contentHash: String) -> Bool {
        items.contains { $0.contentHash == contentHash }
    }

    /// Flips the pin of one entry and returns the new state; nil when there is no such entry or it is a
    /// copied password (those are never pinned: pinned entries outlive every limit).
    @discardableResult
    public mutating func togglePin(id: UUID) -> Bool? {
        guard let index = items.firstIndex(where: { $0.id == id }), !items[index].concealed else { return nil }
        items[index].pinned.toggle()
        return items[index].pinned
    }

    /// Removes one entry and returns it (so its blob can be deleted); nil when there is no such entry.
    @discardableResult
    public mutating func remove(id: UUID) -> ClipboardItem? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        return items.remove(at: index)
    }

    /// Moves an entry to the top with a new date (it was just used). False when there is no such entry.
    @discardableResult
    public mutating func moveToTop(id: UUID, date: Date) -> Bool {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return false }
        var entry = items.remove(at: index)
        entry.date = date
        items.insert(entry, at: 0)
        return true
    }

    /// Removes every entry (every one but the pinned ones when `keepPinned`) and returns what was
    /// removed, newest first.
    @discardableResult
    public mutating func clear(keepPinned: Bool = true) -> [ClipboardItem] {
        let removed = items.filter { !(keepPinned && $0.pinned) }
        items = keepPinned ? items.filter(\.pinned) : []
        return removed
    }

    /// Removes the entries for which `shouldRemove` is true and returns them, newest first.
    @discardableResult
    public mutating func removeAll(where shouldRemove: (ClipboardItem) -> Bool) -> [ClipboardItem] {
        let removed = items.filter(shouldRemove)
        if !removed.isEmpty { items.removeAll(where: shouldRemove) }
        return removed
    }

    /// Removes every copied password and returns them, newest first.
    @discardableResult
    public mutating func removeConcealed() -> [ClipboardItem] {
        removeAll(where: \.concealed)
    }

    /// The order a list shows: pinned entries first, then the rest, each group newest first.
    public var displayItems: [ClipboardItem] {
        items.filter(\.pinned) + items.filter { !$0.pinned }
    }

    /// The entries matching `query`, in display order. Every word of the query must appear in the
    /// preview or the source app's name; case and accents are ignored ("cafe" finds "Café"). An empty
    /// query returns everything. Copied passwords never match a query (their text is masked, and the
    /// source app's name would only point at them), but they are listed when there is none.
    public func search(_ query: String) -> [ClipboardItem] {
        let words = Self.fold(query).split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return displayItems }
        return displayItems.filter { item in
            guard !item.concealed else { return false }
            let haystack = Self.fold(item.preview + " " + (item.sourceName ?? ""))
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
