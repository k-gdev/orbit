import AppKit
import Combine
import OrbitCore

/// Runs the wallpapers while Wallpaper is on: one `WallpaperWindow` per connected display that has a playable
/// wallpaper, one shared `WallpaperPlayer` per distinct source, the pause policy applied per display, and still
/// frames set as desktop pictures. Rebuilds when the screens or the settings change.
///
/// `stop()` closes every window, releases every player and observer, and stops the conditions monitor; it restores
/// nothing else (the feature asks `StillFrameWriter.restoreAll()` to put desktop pictures back).
@MainActor
final class WallpaperManager {
    let settings: WallpaperSettings
    let stills: StillFrameWriter
    private let monitor = WallpaperConditionsMonitor()

    /// Downloaded aerials by id.
    private(set) var aerials: [String: Aerial] = [:]
    private var screens: [String: NSScreen] = [:]
    private var windows: [String: WallpaperWindow] = [:]
    private var shown: [String: WallpaperSource] = [:]
    /// The file each window plays.
    private var videos: [String: URL] = [:]
    private var players: [String: WallpaperPlayer] = [:]
    private var occlusionObservers: [String: NSObjectProtocol] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var cancellables: Set<AnyCancellable> = []
    private(set) var isRunning = false
    /// Whether the last rebuild ran with still frames on (so turning them on sets every window's still once).
    private var stillFramesWereOn = false
    /// Video sources whose refreshed bookmark was saved during this run.
    private var refreshedBookmarks: Set<String> = []

    /// Each display's playback, published after every evaluation (empty when stopped).
    private(set) var states: [String: PlaybackState] = [:]
    var onStatesChange: ([String: PlaybackState]) -> Void = { _ in }

    init(settings: WallpaperSettings, stills: StillFrameWriter) {
        self.settings = settings
        self.stills = stills
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        reloadAerials()
        monitor.onChange = { [weak self] in self?.evaluate() }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        })
        workspaceObservers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification,
                                                                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeSpaceChanged() }
        })
        // @Published fires before the value changes; hopping to the next run loop turn reads the new value.
        settings.$assignments.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        settings.$setStillFrame.dropFirst().removeDuplicates().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuild() }.store(in: &cancellables)
        settings.$pauseOnBattery.combineLatest(settings.$pauseInLowPower).dropFirst().receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.evaluate() }.store(in: &cancellables)
        rebuild()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
        workspaceObservers.removeAll()
        for key in Array(windows.keys) { closeWindow(key) }
        for player in players.values { player.invalidate() }
        players.removeAll()
        monitor.stop()
        monitor.onChange = {}
        stills.cancelAll()
        screens.removeAll()
        stillFramesWereOn = false
        refreshedBookmarks.removeAll()
        states = [:]
        onStatesChange(states)
    }

    /// Re-reads the aerial manifest (cheap: one JSON file and the strings table).
    func reloadAerials() {
        aerials = Dictionary(AerialCatalog.load().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Rebuild

    /// Brings windows, players, still frames and the monitor in line with the connected screens and the settings.
    func rebuild() {
        guard isRunning else { return }
        var refs: [DisplayRef] = []
        screens.removeAll()
        for screen in NSScreen.screens {
            guard let key = DisplayIdentity.key(for: screen) else { continue }
            refs.append(DisplayRef(key: key, name: screen.localizedName))
            screens[key] = screen
        }

        var assignments = settings.assignments
        for move in assignments.adopt(refs) {
            var ledger = settings.desktopPictures
            ledger.move(from: move.from, to: move.to)
            if ledger != settings.desktopPictures { settings.desktopPictures = ledger }
            Log.info("wallpaper: \(move.to) took over the wallpaper saved for \(move.from)")
        }
        // A newly downloaded aerial isn't in the catalog yet: read the manifest again once.
        let assignedAerials = refs.compactMap { assignments[$0.key]?.source.aerialID }
        if assignedAerials.contains(where: { aerials[$0] == nil }) { reloadAerials() }

        var urls: [String: URL] = [:]
        for ref in refs {
            guard let source = assignments[ref.key]?.source else { continue }
            guard let (url, refreshed) = resolve(source) else { continue }
            // Save a refreshed bookmark once per file per run, so a bookmark that keeps reporting stale can't turn
            // save → rebuild → save into a loop.
            if let refreshed, refreshedBookmarks.insert(refreshed.identity).inserted {
                assignments.assign(refreshed, to: ref)
                urls[refreshed.identity] = url
            } else {
                urls[source.identity] = url
            }
        }
        if assignments != settings.assignments { settings.assignments = assignments }

        let desired = WallpaperPlan.desired(screens: refs, assignments: assignments) { urls[$0.identity] != nil }
        let changes = WallpaperPlan.changes(from: shown, to: desired)
        for key in changes.close { closeWindow(key) }
        for key in changes.open + changes.change {
            guard let source = desired[key], let url = urls[source.identity], let screen = screens[key] else { continue }
            show(source, url: url, on: screen, key: key)
        }
        for (key, window) in windows {
            if let screen = screens[key] { window.fit(to: screen) }
        }
        let used = Set(shown.values.map(\.identity))
        for (identity, player) in players where !used.contains(identity) {
            player.invalidate()
            players[identity] = nil
        }

        // Stills are set when a window opens or changes wallpaper, and for every window when still frames are turned
        // on, but not on every rebuild, so a picture the user picks by hand isn't replaced at the next screen change.
        let stillsForAll = settings.setStillFrame && !stillFramesWereOn
        stillFramesWereOn = settings.setStillFrame
        let fresh = Set(changes.open + changes.change)
        for ref in refs {
            if settings.setStillFrame, let source = shown[ref.key] {
                if stillsForAll || fresh.contains(ref.key), let url = urls[source.identity] {
                    stills.apply(source, video: url, toDisplay: ref.key)
                }
            } else {
                stills.requestRestore(display: ref.key)
            }
        }
        stills.removeUnused(keepingSources: assignments.byDisplay.values.map(\.source))

        if windows.isEmpty { monitor.stop() } else { monitor.start() }
        evaluate()
    }

    /// The file to play for `source`, and a refreshed source to save when a video's bookmark found it moved or
    /// stale. Nil when the aerial isn't downloaded or the video is gone.
    private func resolve(_ source: WallpaperSource) -> (URL, WallpaperSource?)? {
        switch source {
        case .aerial(let id):
            return aerials[id]?.videoURL.map { ($0, nil) }
        case .video(let path, let bookmark):
            return WallpaperVideoFile.resolve(path: path, bookmark: bookmark)
        }
    }

    private func show(_ source: WallpaperSource, url: URL, on screen: NSScreen, key: String) {
        let player: WallpaperPlayer
        if let existing = players[source.identity] {
            player = existing
        } else {
            player = WallpaperPlayer(url: url)
            players[source.identity] = player
        }
        let window: WallpaperWindow
        if let existing = windows[key] {
            window = existing
        } else {
            window = WallpaperWindow(screen: screen, displayKey: key)
            windows[key] = window
            occlusionObservers[key] = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                                             object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            }
            window.present()
            // Occlusion may never be reported: look again once the visibility grace period is over.
            DispatchQueue.main.asyncAfter(deadline: .now() + WallpaperVisibility.grace + 0.25) { [weak self] in
                MainActor.assumeIsolated { self?.evaluate() }
            }
        }
        window.attach(player.player)
        shown[key] = source
        videos[key] = url
        Log.info("wallpaper: \(screen.localizedName) shows \(source.identity)")
    }

    /// A Space switch: re-apply the pause policy, put originals back where this Space still shows a still for a
    /// display that no longer wants one, and refresh stale stills on displays that have a wallpaper.
    private func activeSpaceChanged() {
        guard isRunning else { return }
        evaluate()
        stills.attemptPendingRestores()
        if settings.setStillFrame {
            var current: [String: (source: WallpaperSource, video: URL)] = [:]
            for (key, source) in shown {
                if let video = videos[key] { current[key] = (source, video) }
            }
            stills.replaceStaleStills(current)
        }
    }

    private func closeWindow(_ key: String) {
        if let observer = occlusionObservers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(observer) }
        windows.removeValue(forKey: key)?.tearDown()
        shown[key] = nil
        videos[key] = nil
    }

    // MARK: Playback

    /// Applies the pause policy to every display, then plays each shared player while any of its displays plays.
    func evaluate() {
        guard isRunning else { return }
        var perDisplay: [String: PlaybackState] = [:]
        for (key, window) in windows {
            let id = screens[key].flatMap(DisplayIdentity.displayID(for:))
            let asleep = monitor.displaysAsleep || (id.map { CGDisplayIsAsleep($0) != 0 } ?? false)
            let conditions = DisplayConditions(screenCovered: window.isCovered, screenLocked: monitor.screenLocked,
                                               displayAsleep: asleep, onBattery: monitor.onBattery,
                                               lowPowerMode: monitor.lowPowerMode, pauseOnBattery: settings.pauseOnBattery,
                                               pauseInLowPower: settings.pauseInLowPower)
            perDisplay[key] = WallpaperPausePolicy.state(for: conditions)
        }
        var byPlayer: [String: [PlaybackState]] = [:]
        for (key, state) in perDisplay {
            guard let identity = shown[key]?.identity else { continue }
            byPlayer[identity, default: []].append(state)
        }
        for (identity, player) in players {
            guard let displayStates = byPlayer[identity] else { player.setPlaying(false); continue }
            player.setPlaying(PlaybackState.combined(displayStates).isPlaying)
        }
        if perDisplay != states {
            states = perDisplay
            onStatesChange(states)
        }
    }
}

/// Finding a user's video file again.
enum WallpaperVideoFile {
    /// A bookmark for a file the user just chose (Orbit isn't sandboxed: a plain bookmark that follows moves).
    static func bookmark(for url: URL) -> Data? {
        try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// The file behind a `.video` source: the bookmark first (it follows a moved or renamed file), else the saved
    /// path. Returns a refreshed source when the file moved or the bookmark went stale; nil when the file is gone.
    static func resolve(path: String, bookmark: Data?) -> (URL, WallpaperSource?)? {
        if let bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                                  relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path) {
                if stale || url.path != path {
                    return (url, .video(path: url.path, bookmark: self.bookmark(for: url) ?? bookmark))
                }
                return (url, nil)
            }
        }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return (URL(fileURLWithPath: path), nil)
    }
}
