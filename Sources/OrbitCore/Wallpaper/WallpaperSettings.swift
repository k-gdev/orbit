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
        static let syncDisplays = "wallpaper.syncDisplays"
        static let desktopPictures = "wallpaper.desktopPictures"
        /// The first build's display key → URL string map, read once to migrate.
        static let legacyPreviousDesktopPictures = "wallpaper.previousDesktopPictures"
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

    /// Keep every connected display on the same wallpaper (default on): choosing one sets it everywhere, and turning
    /// this on, launching or connecting a display brings the ones that differ onto the main display's. See
    /// `WallpaperSync`.
    @Published public var syncDisplays: Bool { didSet { defaults.set(syncDisplays, forKey: Key.syncDisplays) } }

    /// What Orbit changed about each display's desktop picture: the user's original (with its options), the stills
    /// Orbit set, and which displays wait for their original to come back on the Spaces that still show a still. See
    /// `DesktopPictureLedger`. Stored as JSON; unreadable data reads as empty.
    @Published public var desktopPictures: DesktopPictureLedger {
        didSet {
            if let data = try? JSONEncoder().encode(desktopPictures) { defaults.set(data, forKey: Key.desktopPictures) }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        assignments = defaults.data(forKey: Key.assignments)
            .flatMap { try? JSONDecoder().decode(WallpaperAssignments.self, from: $0) } ?? WallpaperAssignments()
        pauseOnBattery = defaults.object(forKey: Key.pauseOnBattery) as? Bool ?? false
        pauseInLowPower = defaults.object(forKey: Key.pauseInLowPower) as? Bool ?? true
        setStillFrame = defaults.object(forKey: Key.setStillFrame) as? Bool ?? true
        syncDisplays = defaults.object(forKey: Key.syncDisplays) as? Bool ?? true
        if let data = defaults.data(forKey: Key.desktopPictures) {
            desktopPictures = (try? JSONDecoder().decode(DesktopPictureLedger.self, from: data)) ?? DesktopPictureLedger()
        } else if let legacy = defaults.dictionary(forKey: Key.legacyPreviousDesktopPictures) as? [String: String] {
            desktopPictures = DesktopPictureLedger(legacy: legacy)
        } else {
            desktopPictures = DesktopPictureLedger()
        }
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

    /// What cleanup may delete: Orbit's own stills that aren't in `keeping` (stills saved wallpapers use or a display
    /// shows now) and that no display waiting for its original picture may still show on another Space.
    public static func removable(_ files: [String], keeping: Set<String>, ledger: DesktopPictureLedger) -> [String] {
        unused(files, keeping: keeping.union(ledger.protectedStills))
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
