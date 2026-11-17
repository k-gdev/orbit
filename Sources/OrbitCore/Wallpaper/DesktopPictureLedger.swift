import Foundation

/// How a desktop picture is drawn: `NSWorkspace`'s desktop image options as plain values, so the user's own
/// scaling, clipping and fill colour come back exactly when Orbit restores their picture.
public struct DesktopPictureOptions: Codable, Equatable, Sendable {
    /// `NSImageScaling` raw value.
    public var imageScaling: UInt?
    public var allowClipping: Bool?
    /// The fill colour as sRGB components `[red, green, blue, alpha]`, 0…1.
    public var fillColor: [Double]?

    public init(imageScaling: UInt? = nil, allowClipping: Bool? = nil, fillColor: [Double]? = nil) {
        self.imageScaling = imageScaling
        self.allowClipping = allowClipping
        self.fillColor = fillColor
    }
}

/// A display's desktop picture as macOS reports it on the current Space.
public struct DesktopPicture: Codable, Equatable, Sendable {
    /// The image's URL (`absoluteString`).
    public var url: String
    /// Nil when unknown (pictures remembered by the first build, which saved only the URL).
    public var options: DesktopPictureOptions?

    public init(url: URL, options: DesktopPictureOptions?) {
        self.url = url.absoluteString
        self.options = options
    }

    public var fileURL: URL? { URL(string: url) }
}

/// What Orbit changed about each display's desktop picture, so the user's own picture comes back on every Space.
///
/// `NSWorkspace` reads and sets a display's desktop picture for the **current Space** only. So a restore can't be done
/// once and forgotten: when a display stops wanting a still (its wallpaper removed, still frames turned off,
/// Wallpaper stopped), its entry is marked `restorePending`, and every time Orbit looks (a rebuild, a Space change,
/// the next start) the original goes back on whichever Space still shows one of Orbit's stills. A Space showing
/// anything else is the user's choice and is left alone. The entry, and the still files it lists, are kept while
/// that may still be needed; they are protected from cleanup until the display gets a wallpaper again.
public struct DesktopPictureLedger: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        /// The user's picture from before Orbit's still, with its options; nil when the display showed one of Orbit's
        /// stills or nothing readable at the time.
        public var original: DesktopPicture?
        /// The still files Orbit set on this display, oldest first (the last `stillHistory`): any Space may still show
        /// one of them.
        public var stills: [String]
        /// The display no longer wants a still: wherever one of Orbit's stills shows on it, put `original` back.
        public var restorePending: Bool

        public init(original: DesktopPicture?, stills: [String] = [], restorePending: Bool = false) {
            self.original = original
            self.stills = stills
            self.restorePending = restorePending
        }
    }

    /// How many still names an entry keeps.
    public static let stillHistory = 8

    public private(set) var entries: [String: Entry]

    public init(_ entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// The first build's `previousDesktopPictures` (display key → URL string), as entries without options.
    public init(legacy: [String: String]) {
        var entries: [String: Entry] = [:]
        for (key, text) in legacy {
            guard let url = URL(string: text) else { continue }
            entries[key] = Entry(original: DesktopPicture(url: url, options: nil))
        }
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public subscript(key: String) -> Entry? { entries[key] }

    /// Displays waiting for their original picture to come back, sorted.
    public var pendingKeys: [String] { entries.filter { $0.value.restorePending }.map(\.key).sorted() }

    /// Still files that must not be deleted: every still set on a display whose restore is pending, since some Space
    /// may still show it.
    public var protectedStills: Set<String> {
        Set(entries.values.filter(\.restorePending).flatMap(\.stills))
    }

    /// Orbit is about to set still `fileName` on display `key`, which shows `current` on the current Space. Remembers
    /// `current` as the original when there is none yet, or when the display was waiting for a restore (it had no
    /// wallpaper, so a picture of the user's own on this Space is their latest choice). While the display keeps a
    /// wallpaper the first original stays: another Space may show the user's picture only because it never got a
    /// still. Orbit's own stills and unreadable pictures are never remembered.
    public mutating func willSetStill(_ fileName: String, on key: String, current: DesktopPicture?, stillsFolder: URL) {
        var entry = entries[key] ?? Entry(original: nil)
        if let current, let url = current.fileURL, !StillFrame.isStill(url, in: stillsFolder),
           entry.original == nil || entry.restorePending {
            entry.original = current
        }
        entry.stills.removeAll { $0 == fileName }
        entry.stills.append(fileName)
        if entry.stills.count > Self.stillHistory { entry.stills.removeFirst(entry.stills.count - Self.stillHistory) }
        entry.restorePending = false
        entries[key] = entry
    }

    /// Display `key` no longer wants a still. Does nothing for a display Orbit never set a still on.
    public mutating func requestRestore(_ key: String) {
        guard entries[key]?.restorePending == false else { return }
        entries[key]?.restorePending = true
    }

    /// Wallpaper is stopping: every display (connected or not) waits for its original.
    public mutating func requestRestoreAll() {
        for key in entries.keys { entries[key]?.restorePending = true }
    }

    public enum Action: Equatable, Sendable {
        /// Leave the current Space's picture as it is.
        case leave
        /// Set this picture, with its options, on the current Space.
        case restore(DesktopPicture)
    }

    /// What to do for display `key` on the Space that is current now, where it shows `current`: put the original back
    /// only when the display waits for a restore and shows one of Orbit's stills. Never forgets the entry, since other
    /// Spaces may still show a still.
    public func restoreAction(for key: String, current: URL?, stillsFolder: URL) -> Action {
        guard let entry = entries[key], entry.restorePending, let original = entry.original,
              let current, StillFrame.isStill(current, in: stillsFolder) else { return .leave }
        return .restore(original)
    }

    /// On a Space change, a display with a wallpaper gets its current still only where the Space shows an older still
    /// of Orbit's; a Space showing the user's own picture keeps it.
    public static func shouldReplaceStill(current: URL?, with fileName: String, stillsFolder: URL) -> Bool {
        guard let current, StillFrame.isStill(current, in: stillsFolder) else { return false }
        return current.lastPathComponent != fileName
    }

    /// A display's key changed (`WallpaperAssignments.adopt`): its entry follows, unless the new key has its own.
    public mutating func move(from old: String, to new: String) {
        guard entries[new] == nil, let entry = entries.removeValue(forKey: old) else { return }
        entries[new] = entry
    }
}
