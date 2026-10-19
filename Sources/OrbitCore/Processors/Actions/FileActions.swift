import Foundation

/// The file operations behind Copy Path, Copy To, Move To and Terminal.
public enum FileActions {
    /// Names a destination: `(folder, base, ext)` gives an unused `folder/base[.ext]`.
    public typealias DestinationNamer = (_ folder: URL, _ base: String, _ ext: String) -> URL

    /// The default namer: the first name not on disk (`base`, `base-2`, `base-3`…).
    public static let uniqueNamer: DestinationNamer = { folder, base, ext in
        OutputNamer.uniqueURL(in: folder, base: base, ext: ext, exists: { existsOnDisk($0) })
    }

    /// POSIX paths, or `absoluteString` for URI, one per line.
    public static func pathText(_ urls: [URL], style: PathStyle) -> String {
        urls.map { style == .posix ? $0.path : $0.absoluteString }.joined(separator: "\n")
    }

    /// Copies each item into `folder`. A collision gets the next free name. If anything fails (or
    /// `check` throws, for cancellation) the copies made so far are removed again and the error
    /// is rethrown; sources are never touched.
    public static func copy(_ urls: [URL], to folder: URL, name: DestinationNamer = uniqueNamer,
                            check: () throws -> Void = {}) throws -> [URL] {
        try requireFolder(folder)
        let fm = FileManager.default
        var copies: [URL] = []
        do {
            for url in urls {
                try check()
                try refuseInto(url, folder: folder)
                let target = name(folder, OutputNamer.stem(of: url), OutputNamer.fullExtension(of: url))
                try fm.copyItem(at: url, to: target)
                copies.append(target)
            }
            return copies
        } catch {
            var stuck: [URL] = []
            for copy in copies.reversed() {
                do { try fm.removeItem(at: copy) } catch { stuck.append(copy) }
            }
            throw rollbackError(original: error, stuck: stuck.map(\.path), verb: "removed")
        }
    }

    /// Moves each item into `folder`. Refuses (before moving anything) when an item is already in
    /// that folder. If a later move fails (or `check` throws) the earlier moves are put back.
    public static func move(_ urls: [URL], to folder: URL, name: DestinationNamer = uniqueNamer,
                            check: () throws -> Void = {}) throws -> [FileMove] {
        try requireFolder(folder)
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.path
        for url in urls {
            if url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path == target {
                throw OrbitError.unsupported("Already in \(folder.lastPathComponent).")
            }
            try refuseInto(url, folder: folder)
        }
        let fm = FileManager.default
        var moves: [FileMove] = []
        do {
            for url in urls {
                try check()
                let destination = name(folder, OutputNamer.stem(of: url), OutputNamer.fullExtension(of: url))
                try fm.moveItem(at: url, to: destination)
                moves.append(FileMove(from: url, to: destination))
            }
            return moves
        } catch {
            var stuck: [String] = []
            for move in moves.reversed() {
                do { try fm.moveItem(at: move.to, to: move.from) } catch { stuck.append(move.to.path) }
            }
            throw rollbackError(original: error, stuck: stuck, verb: "put back")
        }
    }

    /// The original error when the rollback was clean; otherwise an error that names every file
    /// the rollback could not undo, so the user knows where those files are.
    private static func rollbackError(original: any Error, stuck: [String], verb: String) -> any Error {
        guard !stuck.isEmpty else { return original }
        let reason = original is CancellationError ? "Cancelled" : original.localizedDescription
        return OrbitError.unsupported("\(reason), and these files couldn't be \(verb): \(stuck.joined(separator: ", "))")
    }

    /// A folder is its own terminal directory; a file uses its parent.
    public static func terminalDirectory(for url: URL) -> URL {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            return url
        }
        return url.deletingLastPathComponent()
    }

    private static func requireFolder(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw OrbitError.unsupported("\(folder.lastPathComponent) isn't a folder.")
        }
    }

    /// A folder can't be copied or moved into itself or one of its own subfolders.
    private static func refuseInto(_ item: URL, folder: URL) throws {
        let source = item.resolvingSymlinksInPath().standardizedFileURL.path
        let target = folder.resolvingSymlinksInPath().standardizedFileURL.path
        if target == source || target.hasPrefix(source + "/") {
            throw OrbitError.unsupported("Can't put \(item.lastPathComponent) inside itself.")
        }
    }

    private static func existsOnDisk(_ url: URL) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: url.path) || (try? fm.attributesOfItem(atPath: url.path)) != nil
    }
}
