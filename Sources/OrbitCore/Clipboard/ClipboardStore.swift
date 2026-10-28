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
        public var corruptBackup: URL?
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
            init(from decoder: Decoder) throws {
                item = try? ClipboardItem(from: decoder)
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
    /// file is renamed to `index.corrupt-<date>.json` and the result is empty. Some entries unreadable:
    /// the good ones are returned and a copy of the original is kept.
    public func load(now: Date = Date()) -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else { return LoadResult(items: []) }
        let decoded: LenientIndex? = (try? Data(contentsOf: indexURL))
            .flatMap { try? Self.makeDecoder().decode(LenientIndex.self, from: $0) }
        guard let decoded, decoded.version >= 1, decoded.version <= Self.currentVersion else {
            return LoadResult(items: [], corruptBackup: moveAsideCorruptIndex(now: now))
        }
        let items = decoded.items.compactMap(\.item)
        let dropped = decoded.items.count - items.count
        guard dropped > 0 else { return LoadResult(items: items) }
        return LoadResult(items: items, droppedCount: dropped, corruptBackup: copyAsideIndex(now: now))
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

    private func moveAsideCorruptIndex(now: Date) -> URL? {
        let target = backupURL(now: now)
        do {
            try FileManager.default.moveItem(at: indexURL, to: target)
            return target
        } catch {
            return nil
        }
    }

    private func copyAsideIndex(now: Date) -> URL? {
        let target = backupURL(now: now)
        do {
            try FileManager.default.copyItem(at: indexURL, to: target)
            return target
        } catch {
            return nil
        }
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
    /// saving the index) and returns their names. Only files named like blobs are considered.
    @discardableResult
    public func removeOrphans(keeping referenced: Set<String>) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let orphans = names.filter { Self.isSafePayloadName($0) && !referenced.contains($0) }
        deletePayloads(orphans)
        return orphans
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
