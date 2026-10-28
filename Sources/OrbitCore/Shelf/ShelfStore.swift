import Foundation

/// Persists the shelf's items as JSON (`shelf.json`) in a given folder, so the shelf survives a relaunch.
/// Each item is stored as its path plus bookmark data. The bookmark is not security-scoped (Orbit is not
/// sandboxed); it only lets a file that was renamed or moved on the same volume be found again. The files
/// themselves are never touched.
///
/// Use it from one thread (the app uses the main actor): it remembers bookmarks it has already made so
/// saving after each change doesn't recreate one per item.
public final class ShelfStore {
    public static let fileName = "shelf.json"

    public let directory: URL
    public var fileURL: URL { directory.appending(path: Self.fileName, directoryHint: .notDirectory) }

    private var bookmarks: [String: Data] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    private struct Stored: Codable {
        var version = 1
        var items: [Entry]
    }

    private struct Entry: Codable {
        var path: String
        var bookmark: Data?
    }

    /// The saved items, or an empty shelf when nothing was saved or the file can't be read. An item whose
    /// file is no longer at its path is looked up through its bookmark; if that fails too it keeps its old
    /// path (the caller decides whether to drop it with `ShelfItems.removeMissing`). Never creates anything.
    public func load() -> ShelfItems {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return ShelfItems() }
        bookmarks.removeAll()
        let urls = stored.items.map(resolve)
        return ShelfItems(urls)
    }

    /// Writes `items` (creating the folder if needed). The write is atomic.
    public func save(_ items: ShelfItems) throws {
        let entries = items.urls.map { url in
            let path = url.standardizedFileURL.path
            if bookmarks[path] == nil, let made = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                bookmarks[path] = made
            }
            return Entry(path: path, bookmark: bookmarks[path])
        }
        // Forget bookmarks of items that are gone.
        let live = Set(entries.map(\.path))
        bookmarks = bookmarks.filter { live.contains($0.key) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Stored(items: entries))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    private func resolve(_ entry: Entry) -> URL {
        let direct = URL(fileURLWithPath: entry.path)
        if FileManager.default.fileExists(atPath: entry.path) {
            if let bookmark = entry.bookmark { bookmarks[direct.standardizedFileURL.path] = bookmark }
            return direct
        }
        guard let bookmark = entry.bookmark else { return direct }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale),
              FileManager.default.fileExists(atPath: found.path) else { return direct }
        // A stale bookmark is made again on the next save.
        if !stale { bookmarks[found.standardizedFileURL.path] = bookmark }
        return found
    }
}
