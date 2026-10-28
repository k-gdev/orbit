import AppKit
import AVFoundation
import Combine
import OrbitCore

/// A display as the Wallpaper tab and Settings page list it.
struct WallpaperDisplayItem: Identifiable, Equatable {
    let key: String
    let name: String
    /// "Main display · 3008 × 1692", or "Not connected".
    let detail: String
    let isConnected: Bool

    var id: String { key }
    var ref: DisplayRef { DisplayRef(key: key, name: name) }
}

/// What the Wallpaper panel tab and Settings page show and do. The live model reads the connected screens and the
/// aerial manifest; the snapshot model is built from fixtures and does nothing when clicked.
@MainActor
final class WallpaperModel: ObservableObject {
    let settings: WallpaperSettings
    let thumbnails: WallpaperThumbnails

    /// Connected displays (left to right), then unplugged ones that still have a wallpaper.
    @Published private(set) var displays: [WallpaperDisplayItem] = []
    /// The aerials downloaded on this Mac.
    @Published private(set) var aerials: [Aerial] = []
    /// Each connected display's playback, from `WallpaperManager`.
    @Published var states: [String: PlaybackState] = [:]
    /// Whether Wallpaper is on (its wallpapers can play).
    @Published var isRunning = false

    /// Opens a file panel and assigns the chosen video to the display.
    var chooseVideoFile: (WallpaperDisplayItem) -> Void = { _ in }
    /// Opens System Settings → Wallpaper (where aerials are downloaded).
    var openWallpaperSettings: () -> Void = {}

    private let loadDisplays: () -> [WallpaperDisplayItem]
    private let loadAerials: () -> [Aerial]
    private let fileExists: (String) -> Bool
    private var cancellables: Set<AnyCancellable> = []

    init(settings: WallpaperSettings, thumbnails: WallpaperThumbnails,
         loadDisplays: @escaping () -> [WallpaperDisplayItem], loadAerials: @escaping () -> [Aerial],
         fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        self.settings = settings
        self.thumbnails = thumbnails
        self.loadDisplays = loadDisplays
        self.loadAerials = loadAerials
        self.fileExists = fileExists
        settings.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        thumbnails.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        refresh()
    }

    /// Re-reads the screens and the aerial manifest (the panel calls this when it opens).
    func refresh() {
        let connected = loadDisplays()
        let keys = Set(connected.map(\.key))
        let unplugged = settings.assignments.keys.filter { !keys.contains($0) }.compactMap { key -> WallpaperDisplayItem? in
            guard let assignment = settings.assignments[key] else { return nil }
            return WallpaperDisplayItem(key: key, name: assignment.displayName, detail: "Not connected", isConnected: false)
        }
        displays = connected + unplugged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        aerials = loadAerials()
    }

    var connectedDisplays: [WallpaperDisplayItem] { displays.filter(\.isConnected) }

    // MARK: Reading

    func source(for display: WallpaperDisplayItem) -> WallpaperSource? { settings.assignments[display.key]?.source }

    func aerial(_ id: String) -> Aerial? { aerials.first { $0.id == id } }

    /// Aerials grouped by category, in catalog order.
    var aerialGroups: [(title: String, aerials: [Aerial])] {
        var groups: [(title: String, aerials: [Aerial])] = []
        for aerial in aerials {
            let title = aerial.category ?? "Other"
            if let index = groups.firstIndex(where: { $0.title == title }) {
                groups[index].aerials.append(aerial)
            } else {
                groups.append((title, [aerial]))
            }
        }
        return groups
    }

    /// The source's display name: the aerial's name, or the video's file name without its extension.
    func title(for source: WallpaperSource) -> String {
        switch source {
        case .aerial(let id): aerial(id)?.name ?? "Aerial"
        case .video(let path, _): ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    /// "Aerial · Landscape" or "Video".
    func kind(of source: WallpaperSource) -> String {
        switch source {
        case .aerial(let id): ["Aerial", aerial(id)?.category].compactMap { $0 }.joined(separator: " · ")
        case .video: "Video"
        }
    }

    /// Whether the aerial is downloaded or the video file is where it was.
    func isAvailable(_ source: WallpaperSource) -> Bool {
        switch source {
        case .aerial(let id): aerial(id) != nil
        case .video(let path, _): fileExists(path)
        }
    }

    func thumbnail(for source: WallpaperSource) -> NSImage? {
        thumbnails.image(for: source, aerial: source.aerialID.flatMap(aerial))
    }

    /// One line on the display's playback.
    enum Status: Equatable {
        case none, off, missing, starting
        case playing
        case paused(PauseReason)
    }

    func status(for display: WallpaperDisplayItem) -> Status {
        guard let source = source(for: display) else { return .none }
        guard isAvailable(source) else { return .missing }
        guard isRunning else { return .off }
        switch states[display.key] {
        case .playing: return .playing
        case .paused(let reason): return .paused(reason)
        case nil: return .starting
        }
    }

    // MARK: Changing

    /// Shows `source` on the display, or removes its wallpaper (nil).
    func assign(_ source: WallpaperSource?, to display: WallpaperDisplayItem) {
        if let source {
            settings.assignments.assign(source, to: display.ref)
        } else {
            settings.assignments.remove(display.key)
        }
        refresh()
    }

    // MARK: Live data

    /// The connected screens, left to right (top first on a tie), with the main display marked.
    static func liveDisplays() -> [WallpaperDisplayItem] {
        let main = NSScreen.screens.first
        let sorted = NSScreen.screens.sorted { a, b in
            a.frame.minX != b.frame.minX ? a.frame.minX < b.frame.minX : a.frame.maxY > b.frame.maxY
        }
        return sorted.compactMap { screen in
            guard let key = DisplayIdentity.key(for: screen) else { return nil }
            let size = "\(Int(screen.frame.width)) × \(Int(screen.frame.height))"
            return WallpaperDisplayItem(key: key, name: screen.localizedName,
                                        detail: screen == main ? "Main display · \(size)" : size, isConnected: true)
        }
    }
}

/// Small preview images for wallpapers: an aerial's own `thumbnails/<id>.png`, or a frame decoded from a video
/// (generated once per file and kept in memory).
@MainActor
final class WallpaperThumbnails: ObservableObject {
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    private var failed: Set<String> = []

    func image(for source: WallpaperSource, aerial: Aerial?) -> NSImage? {
        let key = source.identity
        if let cached = images[key] { return cached }
        switch source {
        case .aerial:
            if let url = aerial?.thumbnailURL, let image = NSImage(contentsOf: url) {
                images[key] = image
                return image
            }
            if let video = aerial?.videoURL { generate(key, from: video) }
        case .video(let path, _):
            generate(key, from: URL(fileURLWithPath: path))
        }
        return nil
    }

    /// Fixture images for snapshots.
    func preload(_ image: NSImage, for source: WallpaperSource) {
        images[source.identity] = image
    }

    private func generate(_ key: String, from url: URL) {
        guard !loading.contains(key), !failed.contains(key) else { return }
        loading.insert(key)
        Task { [weak self] in
            let image = await Self.frame(of: url)
            guard let self else { return }
            self.loading.remove(key)
            if let image {
                self.images[key] = image
                self.objectWillChange.send()
            } else {
                self.failed.insert(key)
            }
        }
    }

    nonisolated private static func frame(of url: URL) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        guard let image = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image else { return nil }
        return NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
    }
}
