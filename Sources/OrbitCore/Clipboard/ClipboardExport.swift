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

    /// Removes the entry folders (only folders named by a UUID) last changed more than `maxAge` ago.
    func prune(now: Date) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return }
        for name in names where UUID(uuidString: name) != nil {
            let folder = directory.appending(path: name, directoryHint: .isDirectory)
            guard let changed = (try? fm.attributesOfItem(atPath: folder.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(changed) > Self.maxAge else { continue }
            try? fm.removeItem(at: folder)
        }
    }
}
