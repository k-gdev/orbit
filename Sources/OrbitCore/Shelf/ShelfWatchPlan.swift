import Foundation

/// What to watch on disk while the shelf is open, so a file that leaves its folder (trashed, moved, renamed or
/// deleted in Finder or anywhere else) leaves the shelf at once instead of at the next time the shelf is shown.
///
/// The shelf watches the folders its files are in, not the files: a file that is deleted or renamed is reported
/// by the folder it was in, and watching a handful of folders is far cheaper than watching every file. The
/// folders event stream is busy with everything else in them, so `isRelevant` picks out the events that are
/// about the shelf's own files. The decisions are pure; `ShelfFolderWatcher` runs the stream.
public struct ShelfWatchPlan: Equatable, Sendable {
    /// The names of the shelf's items by the (standardised) path of the folder they are in.
    private var namesByFolder: [String: Set<String>] = [:]

    public init() {}

    /// The plan for `items`, leaving out the ones in `unreachable` (their drive is offline or their check
    /// timed out: watching them would only stall). Anything that is not a file URL, and a file directly in
    /// `/`, is left out: watching `/` would report every change on the disk.
    public init(items: [URL], skipping unreachable: Set<URL> = []) {
        let skipped = Set(unreachable.compactMap(Self.standardPath))
        for url in items {
            guard let path = Self.standardPath(url), !skipped.contains(path) else { continue }
            add(path: path)
        }
    }

    public var isEmpty: Bool { namesByFolder.isEmpty }

    /// The distinct folders the items are in, sorted by path.
    public var folders: [URL] {
        namesByFolder.keys.sorted().map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    /// Whether any of the paths a file system event reported matters to the shelf: the path of an item, a path
    /// inside an item that is a folder, the folder an item is in (it was renamed or removed), or a folder above
    /// that one. Everything else going on in the folders is none of the shelf's business.
    public func isRelevant(_ changedPaths: [String]) -> Bool {
        for raw in changedPaths {
            let changed = Self.trimmed(raw)
            let changedPrefix = Self.directoryPrefix(changed)
            for (folder, names) in namesByFolder {
                if changed == folder || folder.hasPrefix(changedPrefix) { return true }
                let folderPrefix = Self.directoryPrefix(folder)
                guard changed.hasPrefix(folderPrefix) else { continue }
                let name = changed.dropFirst(folderPrefix.count).prefix { $0 != "/" }
                if names.contains(String(name)) { return true }
            }
        }
        return false
    }

    /// The same plan with each folder replaced by `transform(folder)`, and the items in it following. A folder
    /// `transform` answers nil for is dropped with its items. FSEvents reports real paths (`/private/var`, not
    /// `/var`) and only makes sense for a folder that is there, which is what the transform is for.
    public func mapping(folders transform: (URL) -> URL?) -> ShelfWatchPlan {
        var mapped = ShelfWatchPlan()
        for (folder, names) in namesByFolder {
            guard let target = transform(URL(fileURLWithPath: folder, isDirectory: true)) else { continue }
            // Not standardised: that would turn `/private/var` back into `/var`, the very thing a transform undoes.
            mapped.namesByFolder[Self.trimmed(target.path), default: []].formUnion(names)
        }
        return mapped
    }

    // MARK: Paths

    private mutating func add(path: String) {
        let url = URL(fileURLWithPath: path)
        let folder = Self.trimmed(url.deletingLastPathComponent().path)
        guard folder != "/" else { return }
        namesByFolder[folder, default: []].insert(url.lastPathComponent)
    }

    private static func standardPath(_ url: URL) -> String? {
        url.isFileURL ? trimmed(url.standardizedFileURL.path) : nil
    }

    /// `path` without a trailing slash (a folder event may have one), except for `/` itself.
    private static func trimmed(_ path: String) -> String {
        var result = Substring(path)
        while result.count > 1, result.hasSuffix("/") { result = result.dropLast() }
        return String(result)
    }

    /// What every path inside the folder starts with.
    private static func directoryPrefix(_ folder: String) -> String {
        folder == "/" ? "/" : folder + "/"
    }
}
