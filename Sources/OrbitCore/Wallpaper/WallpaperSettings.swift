import Combine
import Foundation

/// Wallpaper's persisted settings, under `wallpaper.` keys.
public final class WallpaperSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let assignments = "wallpaper.assignments"
        static let pauseOnBattery = "wallpaper.pauseOnBattery"
        static let pauseInLowPower = "wallpaper.pauseInLowPower"
        static let setStillFrame = "wallpaper.setStillFrame"
        static let previousDesktopPictures = "wallpaper.previousDesktopPictures"
    }

    /// Each display's wallpaper. Stored as JSON; unreadable data reads as none.
    @Published public var assignments: WallpaperAssignments {
        didSet {
            if let data = try? JSONEncoder().encode(assignments) { defaults.set(data, forKey: Key.assignments) }
        }
    }

    /// Pause every wallpaper while the Mac runs on battery (default off).
    @Published public var pauseOnBattery: Bool { didSet { defaults.set(pauseOnBattery, forKey: Key.pauseOnBattery) } }

    /// Pause every wallpaper in Low Power Mode (default on).
    @Published public var pauseInLowPower: Bool { didSet { defaults.set(pauseInLowPower, forKey: Key.pauseInLowPower) } }

    /// Also set each display's normal desktop picture to a still frame of its wallpaper, so Mission Control and
    /// Space switches match (default on).
    @Published public var setStillFrame: Bool { didSet { defaults.set(setStillFrame, forKey: Key.setStillFrame) } }

    /// Display key → the desktop picture (URL string) it had before Orbit first set a still frame on it, put back
    /// when its wallpaper is removed or Wallpaper is turned off. Maintained by `rememberDesktopPicture` and
    /// `desktopPictureToRestore`.
    @Published public var previousDesktopPictures: [String: String] {
        didSet { defaults.set(previousDesktopPictures, forKey: Key.previousDesktopPictures) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assignments = defaults.data(forKey: Key.assignments)
            .flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        pauseOnBattery = defaults.object(forKey: Key.pauseOnBattery) as? Bool ?? false
        pauseInLowPower = defaults.object(forKey: Key.pauseInLowPower) as? Bool ?? true
        setStillFrame = defaults.object(forKey: Key.setStillFrame) as? Bool ?? true
        previousDesktopPictures = defaults.dictionary(forKey: Key.previousDesktopPictures) as? [String: String] ?? [:]
    }

    /// Call just before Orbit sets a still frame on display `key`, with the picture it shows now. Remembers it only
    /// the first time: a picture is already remembered, or `current` is one of Orbit's own stills, or there is none.
    public func rememberDesktopPicture(_ current: URL?, for key: String, stillsFolder: URL) {
        guard previousDesktopPictures[key] == nil, let current, !StillFrame.isStill(current, in: stillsFolder) else { return }
        previousDesktopPictures[key] = current.absoluteString
    }

    /// Call when display `key` loses its wallpaper (or Wallpaper stops), with the picture it shows now. Returns the
    /// remembered picture to put back, but only while the display still shows Orbit's still: if the user chose
    /// another picture since, theirs stays. Forgets the remembered picture either way.
    public func desktopPictureToRestore(for key: String, current: URL?, stillsFolder: URL) -> URL? {
        guard let saved = previousDesktopPictures.removeValue(forKey: key) else { return nil }
        guard let current, StillFrame.isStill(current, in: stillsFolder) else { return nil }
        return URL(string: saved)
    }
}

/// Names and recognises the still frames Orbit writes to `<support>/Wallpaper/stills/` and sets as desktop pictures.
public enum StillFrame {
    private static let prefixes = ["aerial-", "video-"]

    /// `aerial-<id>.png`, or `video-<hash>.png` where the hash covers the path and modification date, so a replaced or
    /// moved video gets a new file (macOS caches desktop pictures by URL).
    public static func fileName(for source: WallpaperSource, modified: Date?) -> String {
        switch source {
        case .aerial(let id):
            let safe = id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" }
            return "aerial-\(String(String.UnicodeScalarView(safe))).png"
        case .video(let path, _):
            let stamp = modified.map { String(Int64($0.timeIntervalSince1970.rounded())) } ?? "-"
            return "video-\(String(fnv1a("\(path)|\(stamp)"), radix: 16)).png"
        }
    }

    /// True when `url` is a file inside `folder` (Orbit's stills folder).
    public static func isStill(_ url: URL, in folder: URL) -> Bool {
        guard url.isFileURL else { return false }
        let dir = folder.standardizedFileURL.path
        let base = dir.hasSuffix("/") ? dir : dir + "/"
        return url.standardizedFileURL.path.hasPrefix(base)
    }

    /// Of the file names in the stills folder, Orbit's own stills (`aerial-*.png`, `video-*.png`) not in `keeping`.
    public static func unused(_ files: [String], keeping: Set<String>) -> [String] {
        files.filter { name in
            name.hasSuffix(".png") && prefixes.contains(where: name.hasPrefix) && !keeping.contains(name)
        }.sorted()
    }

    /// 64-bit FNV-1a: a stable hash (Swift's `Hasher` is seeded per process).
    private static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return hash
    }
}
