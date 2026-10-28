import AppKit
import AVFoundation
import ImageIO
import OrbitCore
import UniformTypeIdentifiers

/// Sets each display's normal desktop picture to a still frame of its wallpaper (so Mission Control and Space
/// switches match the video), and puts the user's own picture back when the wallpaper goes.
///
/// Stills are PNGs of the frame at 1 s, written to `<support>/Wallpaper/stills/` (`StillFrame.fileName`), and reused
/// while the source is unchanged. `NSWorkspace` reads and sets desktop pictures for the **current Space** only, so
/// the bookkeeping lives in `WallpaperSettings.desktopPictures` (`DesktopPictureLedger`): the user's original picture
/// and options are remembered before Orbit's first still; when a display stops wanting a still its entry waits
/// (`restorePending`), and the original goes back on each Space that still shows one of Orbit's stills, now, on the
/// next Space change, or at the next start. Stills a waiting display may still show are never deleted.
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

    /// The still for `source` (whose video is `video`) becomes display `key`'s desktop picture on the current Space,
    /// once written. The ledger is updated right away (the user's picture remembered, the display no longer waiting
    /// for a restore), so a Space change during the write can't put the original back on a display that has a
    /// wallpaper. A call for another source on the same display cancels this one; a repeat for the same source while
    /// it is being written does nothing.
    func apply(_ source: WallpaperSource, video: URL, toDisplay key: String) {
        if pending[key]?.identity == source.identity { return }
        let name = Self.fileName(for: source, video: video)
        if let screen = Self.screen(for: key) {
            let current = Self.picture(on: screen)
            updateLedger { $0.willSetStill(name, on: key, current: current, stillsFolder: folder) }
        }
        let token = UUID()
        pending[key]?.task.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            defer { if self.pending[key]?.token == token { self.pending[key] = nil } }
            do {
                let folder = try self.makeFolder()
                let still = folder.appending(path: name, directoryHint: .notDirectory)
                if !FileManager.default.fileExists(atPath: still.path) {
                    // Displays sharing a wallpaper share one write; it finishes even if this display moves on.
                    let write = self.writes[name] ?? Task.detached(priority: .utility) { try await Self.writeStill(of: video, to: still) }
                    self.writes[name] = write
                    defer { self.writes[name] = nil }
                    try await write.value
                }
                guard !Task.isCancelled else { return }
                self.setStill(still, onDisplay: key)
            } catch is CancellationError {
            } catch {
                Log.error("wallpaper: still frame for \(source.identity) failed: \(error)")
            }
        }
        pending[key] = (token, source.identity, task)
    }

    /// Display `key` no longer wants a still (its wallpaper was removed, or still frames were turned off): it waits
    /// for its original picture, which goes back on the current Space now if that Space shows one of Orbit's stills.
    func requestRestore(display key: String) {
        pending.removeValue(forKey: key)?.task.cancel()
        updateLedger { $0.requestRestore(key) }
        attemptRestore(display: key)
    }

    /// Puts the original back on the current Space for every connected display still waiting for it (a Space change,
    /// or a rebuild).
    func attemptPendingRestores() {
        for key in settings.desktopPictures.pendingKeys { attemptRestore(display: key) }
    }

    /// Wallpaper is stopping: every display waits for its original, which goes back on the current Space now and on
    /// the other Spaces the next time Wallpaper runs and visits them.
    func restoreAll() {
        cancelAll()
        updateLedger { $0.requestRestoreAll() }
        attemptPendingRestores()
    }

    func cancelAll() {
        for entry in pending.values { entry.task.cancel() }
        pending.removeAll()
    }

    /// After a Space change: each display with a wallpaper gets its current still where this Space shows an older
    /// still of Orbit's (a Space showing the user's own picture keeps it).
    func replaceStaleStills(_ shown: [String: (source: WallpaperSource, video: URL)]) {
        for (key, item) in shown {
            guard let screen = Self.screen(for: key) else { continue }
            let name = Self.fileName(for: item.source, video: item.video)
            if DesktopPictureLedger.shouldReplaceStill(current: NSWorkspace.shared.desktopImageURL(for: screen), with: name,
                                                       stillsFolder: folder) {
                apply(item.source, video: item.video, toDisplay: key)
            }
        }
    }

    /// Deletes Orbit's own stills that no saved wallpaper uses, no connected display shows on the current Space, and no
    /// display waiting for its original may still show on another Space. Only files named by `StillFrame` inside the
    /// stills folder are ever touched.
    func removeUnused(keepingSources sources: [WallpaperSource]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        var keep = Set<String>()
        for source in sources {
            switch source {
            case .aerial: keep.insert(StillFrame.fileName(for: source, modified: nil))
            case .video(let path, _): keep.insert(Self.fileName(for: source, video: URL(fileURLWithPath: path)))
            }
        }
        for screen in NSScreen.screens {
            if let url = NSWorkspace.shared.desktopImageURL(for: screen), StillFrame.isStill(url, in: folder) {
                keep.insert(url.lastPathComponent)
            }
        }
        for name in StillFrame.removable(names, keeping: keep, ledger: settings.desktopPictures) {
            try? FileManager.default.removeItem(at: folder.appending(path: name, directoryHint: .notDirectory))
        }
    }

    // MARK: Internals

    private static let fill: [NSWorkspace.DesktopImageOptionKey: Any] = [
        .imageScaling: NSNumber(value: NSImageScaling.scaleProportionallyUpOrDown.rawValue),
        .allowClipping: NSNumber(value: true),
    ]

    /// Changes the ledger only when the change is real, so repeated calls (every rebuild) don't rewrite defaults.
    private func updateLedger(_ change: (inout DesktopPictureLedger) -> Void) {
        var ledger = settings.desktopPictures
        change(&ledger)
        if ledger != settings.desktopPictures { settings.desktopPictures = ledger }
    }

    private func attemptRestore(display key: String) {
        guard let screen = Self.screen(for: key) else { return }
        let workspace = NSWorkspace.shared
        guard case .restore(let picture) = settings.desktopPictures.restoreAction(
                for: key, current: workspace.desktopImageURL(for: screen), stillsFolder: folder),
              let url = picture.fileURL else { return }
        do {
            try workspace.setDesktopImageURL(url, for: screen, options: picture.options?.workspaceOptions ?? [:])
            Log.info("wallpaper: put the desktop picture of \(screen.localizedName) back on this Space")
        } catch {
            Log.error("wallpaper: couldn't put back \(url.path) on \(screen.localizedName): \(error)")
        }
    }

    private func setStill(_ still: URL, onDisplay key: String) {
        guard let screen = Self.screen(for: key) else { return }
        let workspace = NSWorkspace.shared
        if workspace.desktopImageURL(for: screen)?.standardizedFileURL == still.standardizedFileURL { return }
        do {
            try workspace.setDesktopImageURL(still, for: screen, options: Self.fill)
        } catch {
            Log.error("wallpaper: couldn't set the still frame on \(screen.localizedName): \(error)")
        }
    }

    /// The display's picture and options on the current Space.
    private static func picture(on screen: NSScreen) -> DesktopPicture? {
        let workspace = NSWorkspace.shared
        guard let url = workspace.desktopImageURL(for: screen) else { return nil }
        return DesktopPicture(url: url, options: DesktopPictureOptions(workspace: workspace.desktopImageOptions(for: screen)))
    }

    private static func fileName(for source: WallpaperSource, video: URL) -> String {
        let modified = source.aerialID == nil
            ? (try? video.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate : nil
        return StillFrame.fileName(for: source, modified: modified)
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

extension DesktopPictureOptions {
    /// From `NSWorkspace.desktopImageOptions(for:)`; nil when macOS reports none.
    init?(workspace options: [NSWorkspace.DesktopImageOptionKey: Any]?) {
        guard let options else { return nil }
        let fill = (options[.fillColor] as? NSColor)?.usingColorSpace(.sRGB).map {
            [Double($0.redComponent), Double($0.greenComponent), Double($0.blueComponent), Double($0.alphaComponent)]
        }
        self.init(imageScaling: (options[.imageScaling] as? NSNumber)?.uintValue,
                  allowClipping: (options[.allowClipping] as? NSNumber)?.boolValue,
                  fillColor: fill)
    }

    /// For `NSWorkspace.setDesktopImageURL(_:for:options:)`: only the options that were saved.
    var workspaceOptions: [NSWorkspace.DesktopImageOptionKey: Any] {
        var result: [NSWorkspace.DesktopImageOptionKey: Any] = [:]
        if let imageScaling { result[.imageScaling] = NSNumber(value: imageScaling) }
        if let allowClipping { result[.allowClipping] = NSNumber(value: allowClipping) }
        if let fillColor, fillColor.count == 4 {
            result[.fillColor] = NSColor(srgbRed: fillColor[0], green: fillColor[1], blue: fillColor[2], alpha: fillColor[3])
        }
        return result
    }
}
