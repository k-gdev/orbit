import Foundation

/// What one check of a path found. Only `absent` says the file is not there: a permission error, a timeout or a
/// stale network handle is `unavailable`, which proves nothing about the file.
public enum ShelfProbeResult: Equatable, Sendable {
    case exists, absent, unavailable
}

/// Whether a shelf item can be used right now.
public enum ShelfItemStatus: Equatable, Sendable {
    /// The file is there.
    case available
    /// The file is not there although its volume is: it was deleted or moved away, and the shelf may drop it.
    case missing
    /// The file cannot be reached right now (its drive is unplugged, its network share is asleep or can't be
    /// checked). It may be back later, so the shelf keeps it and shows it dimmed.
    case unreachable
}

/// Tells "gone" from "out of reach", so the shelf never forgets a file only because its drive is offline
/// (spec §5.6: items stay until removed). The decision is pure; `probe` does the file system checks.
public enum ShelfAvailability {
    /// The mount point the item's volume has, judged from the path: `/Volumes/<name>` for anything under
    /// `/Volumes` (USB and network drives mount there, and the folder disappears when they unmount), else `/`
    /// (the startup disk, always there). Volumes mounted elsewhere are treated as the startup disk.
    public static func volumeRoot(of url: URL) -> URL {
        let parts = url.standardizedFileURL.pathComponents // ["/", "Volumes", "NAS", ...]
        if parts.count >= 3, parts[1] == "Volumes" {
            return URL(fileURLWithPath: "/Volumes/\(parts[2])", isDirectory: true)
        }
        return URL(fileURLWithPath: "/", isDirectory: true)
    }

    /// Whether `url` is in a Trash folder: a `.Trash` (the home folder's) or `.Trashes` (another volume's)
    /// path component. A trashed file is only moved there, so its bookmark still finds it; the shelf treats it
    /// as gone instead of following it into the Trash.
    public static func isInTrash(_ url: URL) -> Bool {
        url.standardizedFileURL.pathComponents.contains { $0 == ".Trash" || $0 == ".Trashes" }
    }

    /// Classifies `url`. It is `missing` only when the check says the path is absent AND its volume is mounted
    /// (the volume's folder exists); any error, and any absent path on a volume that is not there, is
    /// `unreachable`.
    public static func status(of url: URL, probe: (URL) -> ShelfProbeResult) -> ShelfItemStatus {
        switch probe(url) {
        case .exists:
            return .available
        case .unavailable:
            return .unreachable
        case .absent:
            let root = volumeRoot(of: url)
            if root.path == "/" { return .missing }
            return probe(root) == .exists ? .missing : .unreachable
        }
    }

    /// Maps the `errno` of a failed check (nil: it succeeded). Only "no such file" and "not a directory"
    /// (a path through a file) mean the path is absent.
    public static func probeResult(errnoValue: Int32?) -> ShelfProbeResult {
        guard let errnoValue else { return .exists }
        return errnoValue == ENOENT || errnoValue == ENOTDIR ? .absent : .unavailable
    }

    /// Checks `url` with `lstat` (a symbolic link counts as there even if its target is not). Blocks as long
    /// as the file system takes to answer, so call it off the main thread.
    public static func probe(_ url: URL) -> ShelfProbeResult {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        return probeResult(errnoValue: result == 0 ? nil : errno)
    }
}
