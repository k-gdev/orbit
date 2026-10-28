import AppKit
import OrbitCore
import ScreenCaptureKit

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
    /// What each thumbnail stands for, and the app they belong to, while the strip is up.
    private var shownTargets: [PreviewTarget] = []
    private var shownPID: pid_t?

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

    /// Reads the app's Accessibility windows off the main thread and, with Screen Recording, its
    /// ScreenCaptureKit windows (every Space), merges them (`PreviewWindowList`), shows the strip at once with
    /// title cards and fills in thumbnails as they are captured.
    private func show(_ pid: pid_t) {
        guard let hover, hover.pid == pid else { return }
        generation += 1
        let generation = generation
        let showMinimised = settings.showMinimised
        Task { @MainActor [weak self] in
            guard let self else { return }
            let accessibility = await Self.readWindows(of: pid)
            let capture = WindowThumbnailer.canCapture ? await self.thumbnailer.captureWindows(of: pid) : []
            guard generation == self.generation else { return }
            let entries = PreviewWindowList.merge(accessibility: accessibility.map(\.info), capture: capture.map(\.info),
                                                  showMinimised: showMinimised)
            let targets = entries.map { entry in
                PreviewTarget(entry: entry, window: entry.accessibilityIndex.map { accessibility[$0] },
                              capture: entry.captureIndex.map { capture[$0] })
            }
            self.present(targets, for: hover, generation: generation)
        }
    }

    private static func readWindows(of pid: pid_t) async -> [AXWindow] {
        await withCheckedContinuation { continuation in
            axQueue.async { continuation.resume(returning: AXWindowService.windows(of: pid)) }
        }
    }

    private func present(_ targets: [PreviewTarget], for hover: DockHover, generation: Int) {
        guard isRunning, generation == self.generation, policy.shown == hover.pid else { return }
        let screen = Self.screen(containing: hover.iconFrame)
        guard !targets.isEmpty, let screen,
              let layout = DockPreviewLayout.make(aspectRatios: targets.map { $0.entry.frame.width / max($0.entry.frame.height, 1) },
                                                  iconFrame: hover.iconFrame, edge: Self.dockEdge, visibleFrame: screen.visibleFrame) else {
            // Nothing to show (no windows): close any strip of another app, and wait for the next hover.
            policy.dismissed()
            hideStrip()
            return
        }
        shownTargets = targets
        shownPID = hover.pid
        model.appName = hover.name
        model.appIcon = NSRunningApplication(processIdentifier: hover.pid)?.icon
        model.items = targets.map { target in
            DockPreviewItem(id: target.id, title: WindowListing.displayTitle(target.entry.title, appName: hover.name),
                            isMinimised: target.entry.isMinimised, isElsewhere: target.entry.isElsewhere, thumbnail: nil)
        }
        model.layout = layout
        model.hovered = layout.thumbnailIndex(at: NSEvent.mouseLocation)

        let panel = self.panel ?? DockPreviewPanel(model: model) { [weak self] in self?.clicked() }
        self.panel = panel
        panel.setFrame(layout.stripFrame, display: true)
        panel.orderFrontRegardless()
        panel.invalidateShadow()
        startTracking()
        loadThumbnails(for: targets, generation: generation, scale: screen.backingScaleFactor)
    }

    /// Captures the thumbnails one by one (minimised windows have none to capture).
    private func loadThumbnails(for targets: [PreviewTarget], generation: Int, scale: CGFloat) {
        let wanted = targets.enumerated().filter { $0.element.capture != nil && !$0.element.entry.isMinimised }
        guard !wanted.isEmpty else { return }
        Task { @MainActor [weak self] in
            for (index, target) in wanted {
                guard let self, let capture = target.capture else { return }
                let image = await self.thumbnailer.thumbnail(of: capture, scale: scale)
                guard generation == self.generation else { return }
                if let image { self.model.setThumbnail(image, at: index) }
            }
            self?.panel?.invalidateShadow()
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

    /// A window Accessibility can reach is brought forward; one seen only elsewhere (another Space, full
    /// screen) activates its app, and macOS switches to a Space with its windows.
    private func clicked() {
        guard let layout = model.layout, let index = layout.thumbnailIndex(at: NSEvent.mouseLocation),
              shownTargets.indices.contains(index) else { return }
        let target = shownTargets[index]
        let pid = shownPID
        dismiss()
        if let window = target.window {
            AXWindowService.bringForward(window)
        } else if let pid, let app = NSRunningApplication(processIdentifier: pid) {
            AppActivation.activate(app)
        }
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
        shownTargets = []
        shownPID = nil
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

/// One thumbnail of the strip: its merged entry, the Accessibility window to raise (nil for a window seen
/// only on another Space) and the capture window for its thumbnail (nil without Screen Recording or a match).
private struct PreviewTarget {
    let entry: PreviewWindowEntry
    let window: AXWindow?
    let capture: SCWindow?
    /// The thumbnail's identity in the strip (every entry has a window, a capture window or both).
    let id: String

    init(entry: PreviewWindowEntry, window: AXWindow?, capture: SCWindow?) {
        self.entry = entry
        self.window = window
        self.capture = capture
        id = window?.id ?? capture.map { "c\($0.windowID)" } ?? "e\(entry.captureIndex ?? -1)"
    }
}

extension AXWindow {
    /// What the merge and matching need.
    var info: AccessibilityWindowInfo {
        AccessibilityWindowInfo(number: number.map(Int.init), title: title, frame: frame, isMinimised: isMinimised, subrole: subrole)
    }
}

extension SCWindow {
    /// What the merge and matching need.
    var info: CaptureWindowInfo {
        CaptureWindowInfo(number: Int(windowID), title: title, frame: frame, isOnScreen: isOnScreen, layer: windowLayer)
    }
}
