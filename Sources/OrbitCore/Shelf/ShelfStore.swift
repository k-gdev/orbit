import Foundation

/// Persists the shelf's items as JSON (`shelf.json`) in a given folder, so the shelf survives a relaunch.
/// Each item is stored as its path plus bookmark data. The bookmark is not security-scoped (Orbit is not
/// sandboxed); it only lets a file that was renamed or moved on the same volume be found again. The files
/// themselves are never touched.
///
/// Safe to call from any thread (an internal lock serialises it), so loading and saving can stay off the
/// main thread: reading `shelf.json` and writing it are the only things `loadStored()` and `save` do for
/// the items themselves except creating bookmarks, and none of that is needed to show the list.
///
/// A shelf file this version cannot fully read (damaged, from a newer Orbit, or with some bad entries) is
/// never silently overwritten: the first `save` after such a `load` moves it aside to
/// `shelf.json.corrupt-<date>` or `shelf.json.newer-<date>` (a name that is never already taken), and if
/// that fails the save throws and leaves the file alone.
public final class ShelfStore: @unchecked Sendable {
    public static let fileName = "shelf.json"
    /// The file format this version writes and fully understands.
    public static let currentVersion = 1

    public let directory: URL
    public var fileURL: URL { directory.appending(path: Self.fileName, directoryHint: .notDirectory) }

    private let now: @Sendable () -> Date
    private let moveItem: @Sendable (URL, URL) throws -> Void
    private let lock = NSLock()
    private var bookmarks: [String: Data] = [:]
    /// Paths a bookmark could not be made for, so a save doesn't retry them every time.
    private var withoutBookmark: Set<String> = []
    private var pendingBackup: BackupReason?

    /// Why the shelf file must be kept before it is replaced.
    enum BackupReason: String {
        case corrupt, newer
    }

    /// `now` and `moveItem` exist for tests (a fixed clock, a move that fails).
    public init(directory: URL,
                now: @escaping @Sendable () -> Date = { Date() },
                moveItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) {
        self.directory = directory
        self.now = now
        self.moveItem = moveItem
    }

    // MARK: Format

    private struct Stored: Decodable {
        var version: Int?
        var items: [Lossy<Entry>]?
    }

    /// Decodes to nil instead of throwing, so one bad element doesn't lose the whole array.
    private struct Lossy<Value: Decodable>: Decodable {
        let value: Value?
        init(from decoder: Decoder) throws { value = try? Value(from: decoder) }
    }

    private struct Entry: Codable {
        var path: String
        var bookmark: Data?

        private enum CodingKeys: String, CodingKey { case path, bookmark }

        init(path: String, bookmark: Data?) {
            self.path = path
            self.bookmark = bookmark
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            path = try container.decode(String.self, forKey: .path)
            guard !path.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .path, in: container, debugDescription: "empty path") }
            // A bookmark that cannot be read just means this item has none.
            bookmark = try? container.decodeIfPresent(Data.self, forKey: .bookmark)
        }
    }

    private struct Output: Encodable {
        var version = ShelfStore.currentVersion
        var items: [Entry]
    }

    // MARK: Load

    /// The saved items exactly as stored: their paths, with no check that the files are still there (so it
    /// can't stall on a drive that has gone away). Returns an empty shelf when nothing was saved or the file
    /// can't be read at all; entries that can't be read are skipped and the rest kept. Never writes.
    public func loadStored() -> ShelfItems {
        lock.lock()
        defer { lock.unlock() }
        bookmarks.removeAll()
        withoutBookmark.removeAll()
        pendingBackup = nil
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ShelfItems() }
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              let raw = stored.items else {
            pendingBackup = .corrupt
            return ShelfItems()
        }
        let entries = raw.compactMap(\.value)
        if entries.count != raw.count { pendingBackup = .corrupt }
        if (stored.version ?? 1) > Self.currentVersion { pendingBackup = .newer }
        var urls: [URL] = []
        for entry in entries {
            let url = URL(fileURLWithPath: entry.path, isDirectory: false)
            urls.append(url)
            if let bookmark = entry.bookmark { bookmarks[url.standardizedFileURL.path] = bookmark }
        }
        return ShelfItems(urls)
    }

    /// `loadStored()`, then an item whose file is no longer at its path is looked up through its bookmark
    /// (renamed or moved on the same volume). An item that can't be found keeps its old path. Checks each
    /// item's path, so call it off the main thread.
    public func load() -> ShelfItems {
        let stored = loadStored()
        return ShelfItems(stored.urls.map { url in
            ShelfAvailability.probe(url) == .absent ? (follow(url) ?? url) : url
        })
    }

    /// Where the file saved at `url` is now, found through its bookmark (without any prompt or mounting), or
    /// nil when it has no bookmark, can't be resolved, or isn't there either. Blocks on the file system.
    public func follow(_ url: URL) -> URL? {
        let key = url.standardizedFileURL.path
        lock.lock()
        let bookmark = bookmarks[key]
        lock.unlock()
        guard let bookmark else { return nil }
        var stale = false
        guard let found = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                   relativeTo: nil, bookmarkDataIsStale: &stale),
              ShelfAvailability.probe(found) == .exists else { return nil }
        // A stale bookmark is made again on the next save.
        lock.lock()
        if !stale { bookmarks[found.standardizedFileURL.path] = bookmark }
        lock.unlock()
        return found
    }

    // MARK: Save

    /// Writes `items` (creating the folder if needed), atomically. A shelf file that `load` could not fully
    /// read is moved aside first; if that fails nothing is written and this throws.
    public func save(_ items: ShelfItems) throws {
        lock.lock()
        defer { lock.unlock() }
        if let reason = pendingBackup {
            try backUpShelfFile(reason)
            pendingBackup = nil
        }
        let entries = items.urls.map { url -> Entry in
            let path = url.standardizedFileURL.path
            if bookmarks[path] == nil, !withoutBookmark.contains(path) {
                if let made = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    bookmarks[path] = made
                } else {
                    withoutBookmark.insert(path)
                }
            }
            return Entry(path: path, bookmark: bookmarks[path])
        }
        // Forget bookmarks of items that are gone.
        let live = Set(entries.map(\.path))
        bookmarks = bookmarks.filter { live.contains($0.key) }
        withoutBookmark = withoutBookmark.filter { live.contains($0) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Output(items: entries))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
    }

    // MARK: Backups

    private func backUpShelfFile(_ reason: BackupReason) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let name = Self.backupFileName(reason: reason, date: now()) { candidate in
            FileManager.default.fileExists(atPath: directory.appending(path: candidate, directoryHint: .notDirectory).path)
        }
        try moveItem(fileURL, directory.appending(path: name, directoryHint: .notDirectory))
    }

    /// `shelf.json.corrupt-20261026-073320` (UTC), with `-2`, `-3`, ... added until `exists` says the name is free.
    static func backupFileName(reason: BackupReason, date: Date, exists: (String) -> Bool) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(fileName).\(reason.rawValue)-\(formatter.string(from: date))"
        var candidate = base
        var counter = 2
        while exists(candidate) {
            candidate = "\(base)-\(counter)"
            counter += 1
        }
        return candidate
    }
}
