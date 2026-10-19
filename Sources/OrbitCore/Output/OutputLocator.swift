import Foundation

public enum OutputLocator {
    public static var fallbackFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Downloads/Orbit", directoryHint: .isDirectory)
    }

    /// The source's folder when writable, otherwise the (created) fallback folder.
    public static func folder(for source: URL, fallback: URL = fallbackFolder, isWritable: (URL) -> Bool) -> (url: URL, usedFallback: Bool) {
        let dir = source.deletingLastPathComponent()
        if isWritable(dir) { return (dir, false) }
        do {
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        } catch {
            Log.error("could not create fallback folder \(fallback.path): \(error.localizedDescription)")
        }
        return (fallback, true)
    }
}
