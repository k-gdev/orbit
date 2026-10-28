import Foundation

/// The clipboard history on disk, in one folder (`~/Library/Application Support/Orbit/Clipboard/` in the
/// app): `index.json` describes the entries, and each entry's content is a blob file next to it named
/// `<uuid>.<txt|rtf|png|json>`. Every write is atomic, the folder and files are private to the user, and
/// the folder is not created until something is written to it.
///
/// A broken index never loses data: it is moved aside as `index.corrupt-<date>.json` and the history
/// starts empty. The store only ever deletes blob files with its own naming pattern.
public struct ClipboardStore: Sendable {
    public static let indexName = "index.json"
    /// The index format this build reads and writes.
    public static let currentVersion = 1

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public var indexURL: URL { directory.appending(path: Self.indexName, directoryHint: .notDirectory) }

    public struct StoreError: Error, CustomStringConvertible {
        public let description: String
    }

    /// What `load()` found.
    public struct LoadResult: Sendable {
        /// The entries, newest first (empty when there is no index or it was unusable).
        public var items: [ClipboardItem]
        /// Entries in the index that could not be read and were left out.
        public var droppedCount = 0
        /// Where the original index was kept when it was unusable or entries had to be dropped.
        /// Nil does NOT mean the index was fine: see `indexWasUnreadable`.
        public var corruptBackup: URL?
        /// True when an index file existed but could not be used (broken, or from a newer Orbit). Set
        /// whether or not keeping a copy of it worked. While true, nothing may be deleted on the strength
        /// of "no entry refers to this blob", and when `corruptBackup` is also nil the file could not be
        /// preserved, so the caller must not overwrite it.
        public var indexWasUnreadable = false
    }

    // MARK: Index

    private struct IndexFile: Codable {
        var version: Int
        var items: [ClipboardItem]
    }

    /// The index with each entry decoded on its own, so one bad entry does not take the rest down.
    private struct LenientIndex: Decodable {
        var version: Int
        var items: [Lossy]

        struct Lossy: Decodable {
            let item: ClipboardItem?
            /// The entry's blob name even when the rest of the entry could not be read.
            let rawPayloadFile: String?

            private enum Keys: String, CodingKey { case payloadFile }

            init(from decoder: Decoder) throws {
                item = try? ClipboardItem(from: decoder)
                rawPayloadFile = (try? decoder.container(keyedBy: Keys.self))
                    .flatMap { try? $0.decodeIfPresent(String.self, forKey: .payloadFile) }
            }
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Reads the index. Missing: empty. Unreadable (not JSON, wrong shape, or a newer version): the
    /// file is renamed to `index.corrupt-<date>.json` (or, if that fails, copied there) and the result is
    /// empty with `indexWasUnreadable` set. Some entries unreadable: the good ones are returned and a copy
    /// of the original is kept. `move` and `copy` are the file operations, replaceable in tests.
    public func load(now: Date = Date(),
                     move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                     copy: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }) -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else { return LoadResult(items: []) }
        let decoded: LenientIndex? = (try? Data(contentsOf: indexURL))
            .flatMap { try? Self.makeDecoder().decode(LenientIndex.self, from: $0) }
        guard let decoded, decoded.version >= 1, decoded.version <= Self.currentVersion else {
            let target = backupURL(now: now)
            var kept: URL?
            if (try? move(indexURL, target)) != nil {
                kept = target
            } else if (try? copy(indexURL, target)) != nil {
                kept = target
            }
            return LoadResult(items: [], corruptBackup: kept, indexWasUnreadable: true)
        }
        let items = decoded.items.compactMap(\.item)
        let dropped = decoded.items.count - items.count
        guard dropped > 0 else { return LoadResult(items: items) }
        let target = backupURL(now: now)
        let kept = (try? copy(indexURL, target)) != nil ? target : nil
        return LoadResult(items: items, droppedCount: dropped, corruptBackup: kept)
    }

    /// Writes the index atomically.
    public func save(_ items: [ClipboardItem]) throws {
        try ensureDirectory()
        let data = try Self.makeEncoder().encode(IndexFile(version: Self.currentVersion, items: items))
        try data.write(to: indexURL, options: .atomic)
        Self.makePrivate(indexURL)
    }

    private func backupURL(now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        let stamp = formatter.string(from: now)
        var candidate = directory.appending(path: "index.corrupt-\(stamp).json", directoryHint: .notDirectory)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appending(path: "index.corrupt-\(stamp)-\(n).json", directoryHint: .notDirectory)
            n += 1
        }
        return candidate
    }

    // MARK: Blobs

    private static let payloadExtensions: Set<String> = ["txt", "rtf", "png", "json"]

    /// Whether `name` looks like a blob this store wrote: `<uuid>.<txt|rtf|png|json>`. Anything else
    /// (path separators, `index.json`, a stranger's file) is refused, so a damaged or tampered index
    /// cannot make the store read or delete files outside its own blobs.
    public static func isSafePayloadName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, payloadExtensions.contains(String(parts[1])) else { return false }
        return UUID(uuidString: String(parts[0])) != nil
    }

    /// A fresh blob name for content of `kind`.
    public static func newPayloadName(for kind: ClipboardKind) -> String {
        "\(UUID().uuidString.lowercased()).\(ClipboardPayload.fileExtension(for: kind))"
    }

    private func blobURL(_ name: String) -> URL? {
        Self.isSafePayloadName(name) ? directory.appending(path: name, directoryHint: .notDirectory) : nil
    }

    /// Where the blob called `name` lives (for example to build a thumbnail without reading it all),
    /// or nil when `name` is not a blob name. The file may not exist.
    public func payloadURL(named name: String) -> URL? { blobURL(name) }

    public func writePayload(_ data: Data, named name: String) throws {
        guard let url = blobURL(name) else { throw StoreError(description: "unsafe blob name \(name)") }
        try ensureDirectory()
        try data.write(to: url, options: .atomic)
        Self.makePrivate(url)
    }

    public func readPayload(named name: String) -> Data? {
        guard let url = blobURL(name) else { return nil }
        return try? Data(contentsOf: url)
    }

    public func payloadExists(named name: String) -> Bool {
        guard let url = blobURL(name) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Deletes blobs by name; names that are not this store's own blob names are ignored.
    public func deletePayloads(_ names: [String]) {
        for name in names {
            guard let url = blobURL(name) else { continue }
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// The entries whose blob file exists (an entry whose content is gone cannot be pasted).
    public func itemsWithPayloads(_ items: [ClipboardItem]) -> [ClipboardItem] {
        items.filter { item in item.payloadFile.map(payloadExists(named:)) ?? false }
    }

    /// Deletes blob files that no entry refers to (left behind by a crash between writing a blob and
    /// saving the index) and returns their names. Only files named like blobs are considered. Blobs that
    /// an `index.corrupt-*` backup still names are kept (they may be what the user wants back), and when
    /// a backup is too broken to read, so that nothing can be ruled out, nothing is deleted at all.
    @discardableResult
    public func removeOrphans(keeping referenced: Set<String>) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        guard let inBackups = blobNamesInBackups(among: names) else { return [] }
        let protected = referenced.union(inBackups)
        let orphans = names.filter { Self.isSafePayloadName($0) && !protected.contains($0) }
        deletePayloads(orphans)
        return orphans
    }

    /// The tidy-up after `load()`: removes orphaned blobs, but only when the index was read cleanly
    /// (nothing unreadable, nothing dropped). After a damaged index nothing is deleted at all.
    @discardableResult
    public func sweepOrphans(after load: LoadResult, keeping referenced: Set<String>) -> [String] {
        guard !load.indexWasUnreadable, load.droppedCount == 0 else { return [] }
        return removeOrphans(keeping: referenced)
    }

    /// The blob names the `index.corrupt-*.json` files among `names` still refer to, or nil when one of
    /// them cannot be parsed (then no blob can be proven unreferenced).
    private func blobNamesInBackups(among names: [String]) -> Set<String>? {
        var found = Set<String>()
        for name in names where name.hasPrefix("index.corrupt-") && name.hasSuffix(".json") {
            let url = directory.appending(path: name, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: url),
                  let index = try? Self.makeDecoder().decode(LenientIndex.self, from: data) else { return nil }
            found.formUnion(index.items.compactMap { $0.item?.payloadFile })
            found.formUnion(index.items.compactMap { $0.rawPayloadFile })
        }
        return found
    }

    // MARK: Folder

    private func ensureDirectory() throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: directory.path) { return }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // The history can hold anything the user copied; keep it out of backups.
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    private static func makePrivate(_ url: URL) {
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
