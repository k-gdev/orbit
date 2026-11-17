import Foundation

/// What plays on a display: a video file of the user's, or one of Apple's downloaded aerials.
public enum WallpaperSource: Codable, Hashable, Sendable {
    /// A video file. `bookmark` follows the file if it is moved or renamed; `path` is where it was last seen.
    case video(path: String, bookmark: Data?)
    /// An aerial from `AerialCatalog`, by its manifest id.
    case aerial(id: String)

    /// A key that is equal for two sources showing the same thing (a video's bookmark bytes don't count). Used to
    /// share one player between displays and to tell whether a display's wallpaper really changed.
    public var identity: String {
        switch self {
        case .video(let path, _): "video:\(path)"
        case .aerial(let id): "aerial:\(id)"
        }
    }

    /// The video's file name ("Rain on glass.mov"); nil for an aerial.
    public var videoFileName: String? {
        guard case .video(let path, _) = self else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// The aerial's id; nil for a video.
    public var aerialID: String? {
        guard case .aerial(let id) = self else { return nil }
        return id
    }
}

/// A connected display as Wallpaper sees it: the stable key from `DisplayIdentity` (the display's UUID, or
/// vendor-model-serial without one) and its localized name.
public struct DisplayRef: Hashable, Sendable {
    public let key: String
    public let name: String

    public init(key: String, name: String) {
        self.key = key
        self.name = name
    }
}

/// One display's wallpaper.
public struct WallpaperAssignment: Codable, Hashable, Sendable {
    public var source: WallpaperSource
    /// The display's name when it was chosen: shown while the display is unplugged, and used to find the display
    /// again if macOS gives it a new key (`WallpaperAssignments.adopt`).
    public var displayName: String

    public init(source: WallpaperSource, displayName: String) {
        self.source = source
        self.displayName = displayName
    }
}

/// Every display's wallpaper, keyed by display key. Displays that are unplugged keep theirs for when they return.
public struct WallpaperAssignments: Codable, Equatable, Sendable {
    public private(set) var byDisplay: [String: WallpaperAssignment]

    public init(_ byDisplay: [String: WallpaperAssignment] = [:]) {
        self.byDisplay = byDisplay
    }

    public var isEmpty: Bool { byDisplay.isEmpty }

    /// The display keys with a wallpaper, sorted.
    public var keys: [String] { byDisplay.keys.sorted() }

    public subscript(key: String) -> WallpaperAssignment? { byDisplay[key] }

    /// Shows `source` on `display`, replacing what it had.
    public mutating func assign(_ source: WallpaperSource, to display: DisplayRef) {
        byDisplay[display.key] = WallpaperAssignment(source: source, displayName: display.name)
    }

    /// Takes the wallpaper off a display; returns what it had.
    @discardableResult
    public mutating func remove(_ key: String) -> WallpaperAssignment? {
        byDisplay.removeValue(forKey: key)
    }

    /// An assignment moved from an old display key to a connected display's new one.
    public struct Move: Equatable, Sendable {
        public let from: String
        public let to: String

        public init(from: String, to: String) {
            self.from = from
            self.to = to
        }
    }

    /// The fallback for a display whose key changed (a new UUID after a firmware update or a port swap): a
    /// connected display with no wallpaper of its own takes over an assignment saved under its name whose key is
    /// not connected. Never takes a connected display's assignment; each saved one moves at most once (the
    /// lowest key first when several share a name). Returns the moves made.
    @discardableResult
    public mutating func adopt(_ screens: [DisplayRef]) -> [Move] {
        let connected = Set(screens.map(\.key))
        var moves: [Move] = []
        for screen in screens where byDisplay[screen.key] == nil {
            guard let orphan = byDisplay.keys.sorted().first(where: { key in
                !connected.contains(key) && byDisplay[key]?.displayName == screen.name
            }), var assignment = byDisplay.removeValue(forKey: orphan) else { continue }
            assignment.displayName = screen.name
            byDisplay[screen.key] = assignment
            moves.append(Move(from: orphan, to: screen.key))
        }
        return moves
    }

    /// The distinct video files assigned to any display, by file name then path (offered as "Your videos" when
    /// choosing a wallpaper for another display).
    public var videos: [WallpaperSource] {
        var seen = Set<String>()
        var result: [WallpaperSource] = []
        for key in keys {
            guard let source = byDisplay[key]?.source, source.videoFileName != nil, seen.insert(source.identity).inserted else { continue }
            result.append(source)
        }
        return result.sorted { ($0.videoFileName ?? "", $0.identity) < ($1.videoFileName ?? "", $1.identity) }
    }
}
