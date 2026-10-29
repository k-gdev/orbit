import AppKit
import AVFoundation
import OrbitCore
import SwiftUI
import UniformTypeIdentifiers

/// Live wallpapers (spec §5.7): a video per display (the user's own file or a downloaded Apple aerial), playing in a
/// desktop-level window that keeps moving while the desktop is in use, pausing when nobody can see it, with a
/// matching still frame as the normal desktop picture.
///
/// `init` only loads settings. `start()` creates the `WallpaperManager` (windows, players, monitors); `stop()` closes
/// everything and puts back the desktop pictures Orbit replaced. Needs no permission.
@MainActor
final class WallpaperFeature: SuiteFeature {
    let id = FeatureID.wallpaper
    private let context: SuiteContext
    private let settings: WallpaperSettings
    private var manager: WallpaperManager?
    private var liveModel: WallpaperModel?

    init(context: SuiteContext) {
        self.context = context
        settings = WallpaperSettings(defaults: context.defaults)
    }

    func start() {
        guard manager == nil else { return }
        let folder = context.supportDirectory.appending(path: "\(FeatureID.wallpaper.title)/stills", directoryHint: .isDirectory)
        let stills = StillFrameWriter(settings: settings, folder: folder) { [context] in
            let url = try context.directory(for: .wallpaper).appending(path: "stills", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        let manager = WallpaperManager(settings: settings, stills: stills)
        manager.onStatesChange = { [weak self] states in self?.liveModel?.states = states }
        self.manager = manager
        manager.start()
        liveModel?.isRunning = true
        liveModel?.states = manager.states
    }

    func stop() {
        guard let manager else { return }
        manager.stop()
        manager.stills.restoreAll()
        self.manager = nil
        liveModel?.isRunning = false
        liveModel?.states = [:]
    }

    func panelDidAppear() {
        model.refresh()
    }

    func makePanelView() -> AnyView { AnyView(WallpaperPanelView(model: model)) }

    func makeSettingsView() -> AnyView {
        model.refresh()
        return AnyView(WallpaperSettingsView(model: model))
    }

    // MARK: Live model

    /// Built the first time the tab or Settings page is shown, never in `init`.
    private var model: WallpaperModel {
        if let liveModel { return liveModel }
        let model = WallpaperModel(settings: settings, thumbnails: WallpaperThumbnails(),
                                   loadDisplays: WallpaperModel.liveDisplays, loadAerials: { AerialCatalog.load() })
        model.isRunning = manager != nil
        model.states = manager?.states ?? [:]
        model.chooseVideoFile = { [weak self] display in self?.chooseVideo(for: display) }
        model.openWallpaperSettings = { [weak self] in self?.openWallpaperSettings() }
        liveModel = model
        return model
    }

    private func chooseVideo(for display: WallpaperDisplayItem) {
        context.closePanel()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Choose a video to play on \(display.name)."
        panel.prompt = "Use Video"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { [weak self] in
            let playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false
            guard let self else { return }
            guard playable else {
                _ = self.context.toasts.show(ToastContent(message: "Can't play \(url.lastPathComponent)",
                                                          detail: "Choose a movie file macOS can play (MOV, MP4, M4V).", isError: true))
                return
            }
            self.model.assign(.video(path: url.path, bookmark: WallpaperVideoFile.bookmark(for: url)), to: display)
        }
    }

    private func openWallpaperSettings() {
        context.closePanel()
        if let url = URL(string: "x-apple.systempreferences:com.apple.Wallpaper-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Snapshots

    /// The real views over fixtures: Kevo's four displays, his four downloaded aerials (their real thumbnails when the
    /// manifest folder has them, read-only; drawn stand-ins otherwise) and one video. Throwaway defaults; nothing
    /// is written, no window opens, no desktop picture changes.
    static func snapshotViews() -> FeatureSnapshotViews {
        let model = fixtureModel()
        return FeatureSnapshotViews(panel: WallpaperPanelView(model: model), settings: WallpaperSettingsView(model: model))
    }

    static func fixtureModel() -> WallpaperModel {
        let settings = WallpaperSettings(defaults: SnapshotFixtures.defaults())
        settings.syncDisplays = false  // the fixture's displays each show something different
        let displays = [
            WallpaperDisplayItem(key: "fixture-k272hul", name: "K272HUL", detail: "2560 × 1440", isConnected: true),
            WallpaperDisplayItem(key: "fixture-p27u-1", name: "P27u-20 (1)", detail: "Main display · 3008 × 1692", isConnected: true, isMain: true),
            WallpaperDisplayItem(key: "fixture-q27g4zd", name: "Q27G4ZD", detail: "2560 × 1440", isConnected: true),
            WallpaperDisplayItem(key: "fixture-p27u-2", name: "P27u-20 (2)", detail: "3008 × 1692", isConnected: true),
        ]
        let thumbnailFolder = AerialCatalog.locations.first?.thumbnails
        func aerial(_ id: String, _ name: String, _ category: String) -> Aerial {
            let thumbnail = thumbnailFolder?.appending(path: "\(id).png", directoryHint: .notDirectory)
            return Aerial(id: id, name: name, category: category, videoURL: URL(fileURLWithPath: "/fixture/\(id).mov"),
                          thumbnailURL: thumbnail.flatMap { FileManager.default.isReadableFile(atPath: $0.path) ? $0 : nil })
        }
        let aerials = [
            aerial("4C108785-A7BA-422E-9C79-B0129F1D5550", "Tahoe Day", "Landscape"),
            aerial("6D6834A4-2F0F-479A-B053-7D4DC5CB8EB7", "Sequoia Sunrise", "Landscape"),
            aerial("8A57476A-E177-4AAD-B317-643F681584E1", "Oregon Sunset", "Landscape"),
            aerial("C7AD3D0A-7EDF-412C-A237-B3C9D27381A1", "Alaskan Jellies Light", "Underwater"),
        ]
        let rain = WallpaperSource.video(path: "/Users/kevo/Movies/Rain on glass.mov", bookmark: nil)
        settings.assignments.assign(.aerial(id: aerials[0].id), to: displays[1].ref)
        settings.assignments.assign(rain, to: displays[2].ref)
        settings.assignments.assign(.aerial(id: aerials[3].id), to: displays[3].ref)

        let thumbnails = WallpaperThumbnails()
        let standIns: [(WallpaperSource, [NSColor])] = [
            (.aerial(id: aerials[0].id), [NSColor(srgbRed: 0.42, green: 0.62, blue: 0.86, alpha: 1), NSColor(srgbRed: 0.20, green: 0.36, blue: 0.30, alpha: 1)]),
            (.aerial(id: aerials[1].id), [NSColor(srgbRed: 0.96, green: 0.70, blue: 0.48, alpha: 1), NSColor(srgbRed: 0.30, green: 0.22, blue: 0.20, alpha: 1)]),
            (.aerial(id: aerials[2].id), [NSColor(srgbRed: 0.98, green: 0.55, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.22, green: 0.18, blue: 0.32, alpha: 1)]),
            (.aerial(id: aerials[3].id), [NSColor(srgbRed: 0.10, green: 0.28, blue: 0.46, alpha: 1), NSColor(srgbRed: 0.02, green: 0.06, blue: 0.14, alpha: 1)]),
            (rain, [NSColor(srgbRed: 0.55, green: 0.62, blue: 0.70, alpha: 1), NSColor(srgbRed: 0.18, green: 0.22, blue: 0.28, alpha: 1)]),
        ]
        for (source, colors) in standIns {
            let real = source.aerialID.flatMap { id in aerials.first { $0.id == id }?.thumbnailURL }.flatMap(NSImage.init(contentsOf:))
            thumbnails.preload(real ?? fixtureImage(colors), for: source)
        }

        let model = WallpaperModel(settings: settings, thumbnails: thumbnails, loadDisplays: { displays },
                                   loadAerials: { aerials }, fileExists: { _ in true })
        model.isRunning = true
        model.states = [displays[1].key: .playing, displays[2].key: .paused(.screenCovered), displays[3].key: .playing]
        return model
    }

    /// A soft two-colour gradient standing in for a thumbnail.
    private static func fixtureImage(_ colors: [NSColor]) -> NSImage {
        NSImage(size: NSSize(width: 214, height: 120), flipped: false) { rect in
            NSGradient(colors: colors)?.draw(in: rect, angle: -90)
            return true
        }
    }
}
