import AppKit
import AVFoundation
import ImageIO
import OrbitCore
import UniformTypeIdentifiers

/// Sets each display's normal desktop picture to a still frame of its wallpaper (so Mission Control and Space
/// switches match the video), and puts the previous picture back when the wallpaper goes.
///
/// Stills are PNGs of the frame at 1 s, written to `<support>/Wallpaper/stills/` (`StillFrame.fileName`), and reused
/// while the source is unchanged. Before Orbit's first still on a display, the picture it had is remembered in
/// `WallpaperSettings.previousDesktopPictures`; `restore` puts it back only while Orbit's still is still showing.
@MainActor
final class StillFrameWriter {
    private let settings: WallpaperSettings
    /// `<support>/Wallpaper/stills/` (not created until a still is written).
    let folder: URL
    private let makeFolder: () throws -> URL
    private var pending: [String: (token: UUID, identity: String, task: Task<Void, Never>)] = [:]
    /// Still files being written, by file name.
    private var writes: [String: Task<Void, Error>] = [:]

    /// `makeFolder` creates and returns the stills folder (`context.directory(for: .wallpaper)/stills`); `folder`
    /// is the same path, for checks that must not create it.
    init(settings: WallpaperSettings, folder: URL, makeFolder: @escaping () throws -> URL) {
        self.settings = settings
        self.folder = folder
        self.makeFolder = makeFolder
    }

    /// The still for `source` (whose video is `video`) becomes display `key`'s desktop picture, once written. A call
    /// for another source on the same display cancels this one; a repeat for the same source while it is being
    /// written does nothing.
    func apply(_ source: WallpaperSource, video: URL, toDisplay key: String) {
        if pending[key]?.identity == source.identity { return }
        let token = UUID()
        pending[key]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.pending[key]?.token == token { self.pending[key] = nil } }
            do {
                let folder = try self.makeFolder()
                let modified = source.aerialID == nil
                    ? (try? video.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
                let still = folder.appending(path: StillFrame.fileName(for: source, modified: modified), directoryHint: .notDirectory)
                if !FileManager.default.fileExists(atPath: still.path) {
                    // Displays sharing a wallpaper share one write; it finishes even if this display moves on.
                    let name = still.lastPathComponent
                    let write = self.writes[name] ?? Task.detached(priority: .utility) { try await Self.writeStill(of: video, to: still) }
                    self.writes[name] = write
                    defer { self.writes[name] = nil }
                    try await write.value
                }
                guard !Task.isCancelled else { return }
                self.setDesktopPicture(still, onDisplay: key)
            } catch is CancellationError {
            } catch {
                Log.error("wallpaper: still frame for \(source.identity) failed: \(error)")
            }
        }
        pending[key] = (token, source.identity, task)
    }

    /// Display `key` no longer shows a wallpaper (or still frames were turned off, or Wallpaper stopped): put its
    /// previous desktop picture back if Orbit's still is what it shows. A display that isn't connected keeps its
    /// remembered picture until it returns.
    func restore(display key: String) {
        pending.removeValue(forKey: key)?.task.cancel()
        guard settings.previousDesktopPictures[key] != nil, let screen = Self.screen(for: key) else { return }
        let workspace = NSWorkspace.shared
        guard let target = settings.desktopPictureToRestore(for: key, current: workspace.desktopImageURL(for: screen),
                                                            stillsFolder: folder) else { return }
        do {
            try workspace.setDesktopImageURL(target, for: screen, options: workspace.desktopImageOptions(for: screen) ?? Self.fill)
            Log.info("wallpaper: restored the desktop picture of \(screen.localizedName)")
        } catch {
            Log.error("wallpaper: couldn't restore \(target.path) on \(screen.localizedName): \(error)")
        }
    }

    /// Every connected display with a remembered picture gets it back (Wallpaper is stopping).
    func restoreAll() {
        for key in settings.previousDesktopPictures.keys.sorted() { restore(display: key) }
        cancelAll()
    }

    func cancelAll() {
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
    }

    /// Deletes Orbit's own stills that no saved wallpaper uses and no connected display shows. Only files named by
    /// `StillFrame` inside the stills folder are ever touched.
    func removeUnused(keepingSources sources: [WallpaperSource]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var keep = Set<String>()
        for source in sources {
            switch source {
            case .aerial: keep.insert(StillFrame.fileName(for: source, modified: nil))
            case .video(let path, _):
                let modified = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                keep.insert(StillFrame.fileName(for: source, modified: modified))
            }
        }
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), StillFrame.isStill(url, in: folder) {
                keep.insert(url.lastPathComponent)
            }
        }
        for name in StillFrame.unused(names, keeping: keep) {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    // MARK: Internals

    private static let fill: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
        .allowClipping: NSNumber(value: true),
    ]

    private func setDesktopPicture(_ still: URL, onDisplay key: String) {
        guard let screen = Self.screen(for: key) else { return }
        let workspace = NSWorkspace.shared
        let current = workspace.desktopImageURL(for: screen)
        if current?.standardizedFileURL == still.standardizedFileURL { return }
        settings.rememberDesktopPicture(current, for: key, stillsFolder: folder)
        do {
            try workspace.setDesktopImageURL(still, for: screen, options: Self.fill)
        } catch {
            Log.error("wallpaper: couldn't set the still frame on \(screen.localizedName): \(error)")
        }
    }

    private static func screen(for key: String) -> NSScreen? {
        NSScreen.screens.first { DisplayIdentity.key(for: $0) == key }
    }

    /// Decodes the frame at 1 s (or the first frame of a shorter video) and writes it as a PNG, off the main thread.
    nonisolated private static func writeStill(of video: URL, to destination: URL) async throws {
        let asset = AVURLAsset(url: video)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let duration = try await asset.load(.duration)
        let second = CMTime(seconds: 1, preferredTimescale: 600)
        let time = duration.isValid && duration > second ? second : .zero
        let image = try await generator.image(at: time).image
        try Task.checkCancellation()
        let data = NSMutableData()
        guard let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(target, image, nil)
        guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: destination, options: .atomic)
    }
}
