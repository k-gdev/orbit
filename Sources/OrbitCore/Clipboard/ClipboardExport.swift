import Foundation

/// Where an image entry becomes a real file for a moment, so it can be opened in Preview or dragged
/// into Finder, Mail or Slack (`~/Library/Caches/Orbit/Clipboard/` in the app). Each entry gets its own
/// folder, named by its id, holding `Clipboard Image.png`, so the dragged file has a readable name.
/// Exports are throwaway: every write also removes entry folders more than a day old.
public struct ClipboardExportFolder: Sendable {
    public static let fileName = "Clipboard Image.png"
    /// How long an exported file is kept.
    public static let maxAge: TimeInterval = 86_400

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// Orbit's own caches folder.
    public static var standard: ClipboardExportFolder {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return ClipboardExportFolder(directory: caches.appending(path: "Orbit/Clipboard", directoryHint: .isDirectory))
    }

    /// Writes `png` as the entry's file and returns its URL (the same file again for the same entry).
    public func writeImage(_ png: Data, for id: UUID, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appending(path: Self.fileName, directoryHint: .notDirectory)
        try png.write(to: url, options: .atomic)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        prune(now: now)
        return url
    }

    /// Removes the export folders of entries that left the history (removed, cleared or evicted).
    public func remove(_ ids: [UUID]) {
        for id in ids { try? FileManager.default.removeItem(at: directory.appending(path: id.uuidString, directoryHint: .isDirectory)) }
    }

    /// Removes the entry folders whose entry is no longer in the history, and those older than `maxAge` (at load,
    /// so exports left by an entry that went while Orbit wasn't running don't stay on disk).
    public func sweep(keeping ids: Set<UUID>, now: Date = Date()) {
        prune(now: now) { !ids.contains($0) }
    }

    /// Removes the entry folders (only folders named by a UUID) last changed more than `maxAge` ago, or for
    /// which `alsoRemove` says yes.
    func prune(now: Date, alsoRemove: (UUID) -> Bool = { _ in false }) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names {
            guard let id = UUID(uuidString: name) else { continue }
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            let changed = (try? fm.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date
            let aged = changed.map { now.timeIntervalSince($0) > Self.maxAge } ?? false
            guard aged || alsoRemove(id) else { continue }
            try? fm.removeItem(at: folder)
        }
    }
}
