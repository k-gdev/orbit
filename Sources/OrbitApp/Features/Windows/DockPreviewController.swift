import AppKit
import OrbitCore

/// The Dock preview: hovering a running app's Dock icon for `previewDelay` shows a glass strip of its
/// windows above the icon (thumbnails with Screen Recording, title cards without); hovering a thumbnail
/// shows its title, clicking it brings that window forward. The strip closes when the pointer leaves the
/// icon, the strip and the gap between them, on any click elsewhere, or when the Space changes.
///
/// `WindowsFeature` creates this only while the feature is on, "Dock preview" is on and Accessibility is
/// granted. Between `start()` and the first hover the only cost is the Dock observer; the pointer timer and
/// click monitor exist only while the strip is on screen. `stop()` releases everything.
@MainActor
final class DockPreviewController {
    /// How long the pointer may be outside the hover region before the strip closes.
    static let leaveGrace: TimeInterval = 0.12

    private let settings: WindowsSettings
    private let watcher = DockWatcher()
    private let thumbnailer = WindowThumbnailer()
    private let model = DockPreviewModel()
    private var panel: DockPreviewPanel?

    private var policy = DockHoverPolicy()
    /// The latest hovered app icon (nil: the pointer is not on an app's icon).
    private var hover: DockHover?
    private var delayWork: DispatchWorkItem?
    /// Bumped whenever what is shown changes, so late window reads and captures are dropped.
    private var generation = 0
    private var shownWindows: [AXWindow] = []

    private var pointerTimer: Timer?
    private var outsideSince: Date?
    private var clickMonitor: Any?
    private var spaceObserver: NSObjectProtocol?
    private var isRunning = false

    private static let axQueue = DispatchQueue(label: "com.orbit.windows.dock-preview", qos: .userInteractive)

    init(settings: WindowsSettings) {
        self.settings = settings
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        watcher.onHover = { [weak self] hover in self?.hoverChanged(hover) }
        watcher.start()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        watcher.stop()
        watcher.onHover = { _ in }
        cancelDelay()
        dismiss()
        thumbnailer.clear()
        panel?.close()
        panel = nil
    }

    // MARK: Hover

    private func hoverChanged(_ hover: DockHover?) {
        self.hover = hover
        perform(policy.hoverChanged(to: hover?.pid, delay: settings.previewDelay))
    }

    private func perform(_ command: DockHoverPolicy.Command) {
        switch command {
        case .none:
            break
        case .schedule(let pid, let delay):
            cancelDelay()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.delayWork = nil
                    self.perform(self.policy.delayElapsed(for: pid))
                }
            }
            delayWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        case .cancelSchedule:
            cancelDelay()
        case .show(let pid):
            show(pid)
        case .hide:
            hideStrip()
        }
    }

    private func cancelDelay() {
        delayWork?.cancel()
        delayWork = nil
    }

    // MARK: Showing

    /// Reads the app's windows off the main thread, then shows the strip at once with title cards and fills
    /// in thumbnails as they are captured.
    private func show(_ pid: pid_t) {
        guard let hover, hover.pid == pid else { return }
        generation += 1
        let generation = generation
        let showMinimised = settings.showMinimised
        Self.axQueue.async {
            let windows = AXWindowService.listedWindows(of: pid, showMinimised: showMinimised)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.present(windows, for: hover, generation: generation) }
            }
        }
    }

    private func present(_ windows: [AXWindow], for hover: DockHover, generation: Int) {
        guard isRunning, generation == self.generation, policy.shown == hover.pid else { return }
        let screen = Self.screen(containing: hover.iconFrame)
        guard !windows.isEmpty, let screen,
              let layout = DockPreviewLayout.make(aspectRatios: windows.map { $0.frame.width / max($0.frame.height, 1) },
                                                  iconFrame: hover.iconFrame, edge: Self.dockEdge, visibleFrame: screen.visibleFrame) else {
            // Nothing to show (no windows): close any strip of another app, and wait for the next hover.
            policy.dismissed()
            hideStrip()
            return
        }
        shownWindows = windows
        model.appName = hover.name
        model.appIcon = NSRunningApplication(processIdentifier: hover.pid)?.icon
        model.items = windows.map { window in
            DockPreviewItem(id: window.id, title: WindowListing.displayTitle(window.title, appName: hover.name),
                            isMinimised: window.isMinimised, thumbnail: nil)
        }
        model.layout = layout
        model.hovered = layout.thumbnailIndex(at: NSEvent.mouseLocation)

        let panel = self.panel ?? DockPreviewPanel(model: model) { [weak self] in self?.clicked() }
        self.panel = panel
        panel.setFrame(layout.stripFrame, display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startTracking()
        loadThumbnails(for: windows, pid: hover.pid, generation: generation, scale: screen.backingScaleFactor)
    }

    private func loadThumbnails(for windows: [AXWindow], pid: pid_t, generation: Int, scale: CGFloat) {
        guard WindowThumbnailer.canCapture, windows.contains(where: { !$0.isMinimised }) else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captureWindows = await self.thumbnailer.captureWindows(of: pid)
            guard generation == self.generation else { return }
            let pairs = WindowMatcher.match(
                axWindows: windows.map(\.descriptor),
                captureWindows: captureWindows.map { WindowDescriptor(number: Int($0.windowID), title: $0.title, frame: $0.frame) })
            for pair in pairs where !windows[pair.ax].isMinimised {
                let image = await self.thumbnailer.thumbnail(of: captureWindows[pair.capture], scale: scale)
                guard generation == self.generation else { return }
                if let image { self.model.setThumbnail(image, at: pair.ax) }
            }
            self.panel?.invalidateShadow()
        }
    }

    // MARK: Tracking and closing

    private func startTracking() {
        outsideSince = nil
        if pointerTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.trackPointer() }
            }
            RunLoop.main.add(timer, forMode: .common)
            pointerTimer = timer
        }
        if clickMonitor == nil {
            // Clicks anywhere else (the Dock icon itself included) close the strip; clicks in it are local.
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
        if spaceObserver == nil {
            spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.dismiss() }
            }
        }
    }

    private func stopTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
        spaceObserver = nil
        outsideSince = nil
    }

    private func trackPointer() {
        guard let layout = model.layout else { return }
        let point = NSEvent.mouseLocation
        let index = layout.thumbnailIndex(at: point)
        if index != model.hovered { model.hovered = index }
        // On an app's Dock icon the Dock's own hover reports decide (switching apps, for instance). The
        // 60 pt allowance covers Dock magnification, yet a hover the Dock never cleared can't keep the strip
        // up once the pointer is clearly elsewhere.
        let onHoveredIcon = hover.map { $0.iconFrame.insetBy(dx: -60, dy: -60).contains(point) } ?? false
        if onHoveredIcon || layout.hoverRegionContains(point) {
            outsideSince = nil
            return
        }
        let now = Date()
        guard let since = outsideSince else { outsideSince = now; return }
        if now.timeIntervalSince(since) >= Self.leaveGrace { perform(policy.pointerLeft()) }
    }

    private func clicked() {
        guard let layout = model.layout, let index = layout.thumbnailIndex(at: NSEvent.mouseLocation),
              shownWindows.indices.contains(index) else { return }
        let window = shownWindows[index]
        dismiss()
        AXWindowService.bringForward(window)
    }

    /// Closes the strip for a reason other than the pointer leaving; the next hover waits for the delay.
    private func dismiss() {
        policy.dismissed()
        cancelDelay()
        hideStrip()
    }

    private func hideStrip() {
        generation += 1
        stopTracking()
        panel?.orderOut(nil)
        model.clear()
        shownWindows = []
    }

    // MARK: Screen and Dock

    private static func screen(containing rect: CGRect) -> NSScreen? {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) }
            ?? NSScreen.screens.max { $0.frame.intersection(rect).width < $1.frame.intersection(rect).width }
    }

    /// The Dock's edge from its `orientation` preference, read without creating a defaults object.
    private static var dockEdge: DockEdge {
        let value = CFPreferencesCopyAppValue("orientation" as CFString, DockWatcher.dockBundleID as CFString) as? String
        return DockEdge(orientation: value)
    }
}
