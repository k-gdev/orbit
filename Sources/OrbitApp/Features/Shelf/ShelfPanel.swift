import AppKit
import OrbitCore
import SwiftUI

/// The floating shelf window: borderless, clear (the SwiftUI content draws the glass), on every Space and
/// over full-screen apps, and non-activating, so dragging a file onto it, or a file off it, never makes
/// Orbit the active app or pulls the frontmost app's windows back.
final class ShelfPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: ShelfPlacement.defaultSize),
                   styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: true)
        contentView = content
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false // the content's own handle moves it (`performDrag`)
        animationBehavior = .none
        minSize = ShelfPlacement.minimumSize
        level = .floating
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The shelf is placed by `ShelfPlacement` and may be dragged anywhere, so AppKit must not move it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the SwiftUI shelf. The first click on it works even though the panel never becomes key.
private final class ShelfHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// The panel's content view: the SwiftUI shelf, a resize grip in the bottom-right corner, and the drop
/// target for files dragged onto the shelf.
final class ShelfContentView: NSView {
    private let model: ShelfModel
    private let host: ShelfHostingView
    private let grip = ShelfResizeGrip()
    /// Called with the files dropped on the shelf.
    var onDrop: ([URL]) -> Void = { _ in }

    /// `decorate` wraps the SwiftUI content (the snapshot CLI uses it to set the environment, which does
    /// not reach into this separate hosting view on its own).
    @MainActor
    init(model: ShelfModel, close: @escaping () -> Void, decorate: (AnyView) -> AnyView = { $0 }) {
        self.model = model
        host = ShelfHostingView(rootView: decorate(AnyView(ShelfStripView(model: model, close: close))))
        super.init(frame: NSRect(origin: .zero, size: ShelfPlacement.defaultSize))
        host.sizingOptions = [] // the window's size comes from the user, never from the SwiftUI content
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        addSubview(host)
        grip.frame = NSRect(x: bounds.maxX - ShelfResizeGrip.side - 5, y: 5, width: ShelfResizeGrip.side, height: ShelfResizeGrip.side)
        grip.autoresizingMask = [.minXMargin, .maxYMargin]
        addSubview(grip)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Drop target

    /// What to answer a drag that carries files: a copy cursor ("+") when the source allows it. The shelf
    /// only keeps a reference; the source (Finder) leaves its files alone on a copy. Drags that started on
    /// the shelf itself are refused (dropping an entry back on the shelf does nothing).
    static func operation(for mask: NSDragOperation, fromShelf: Bool) -> NSDragOperation {
        guard !fromShelf else { return [] }
        for candidate in [NSDragOperation.copy, .generic, .link] where mask.contains(candidate) { return candidate }
        return []
    }

    /// Whether the drag that entered carries file URLs (read once per drag, not on every mouse move).
    private var dragCarriesFiles = false

    private func operation(for sender: NSDraggingInfo) -> NSDragOperation {
        guard dragCarriesFiles else { return [] }
        return Self.operation(for: sender.draggingSourceOperationMask, fromShelf: sender.draggingSource is ShelfDragSourceView)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        dragCarriesFiles = sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self],
                                                                   options: [.urlReadingFileURLsOnly: true])
        let operation = operation(for: sender)
        MainActor.assumeIsolated { model.isDropTargeted = operation != [] }
        return operation
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        operation(for: sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragCarriesFiles = false
        MainActor.assumeIsolated { model.isDropTargeted = false }
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragCarriesFiles = false
        MainActor.assumeIsolated { model.isDropTargeted = false }
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        MainActor.assumeIsolated { model.isDropTargeted = false }
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty, operation(for: sender) != [] else { return false }
        onDrop(urls)
        return true
    }
}

/// The diagonal grip at the bottom-right corner that resizes the shelf. It keeps the shelf's top-left
/// corner where it is and holds the size between the minimum and the screen.
final class ShelfResizeGrip: NSView {
    static let side: CGFloat = 20

    private var startMouse = NSPoint.zero
    private var startFrame = NSRect.zero

    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.7).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        // Three short diagonals, longest nearest the corner.
        for inset in [CGFloat(4), 8, 12] {
            path.move(to: NSPoint(x: bounds.maxX - 3, y: bounds.minY + inset))
            path.line(to: NSPoint(x: bounds.maxX - inset, y: bounds.minY + 3))
        }
        path.stroke()
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        startMouse = NSEvent.mouseLocation
        startFrame = window.frame
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screenFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? startFrame
        let width = min(max(startFrame.width + (mouse.x - startMouse.x), ShelfPlacement.minimumSize.width), max(screenFrame.width, ShelfPlacement.minimumSize.width))
        let height = min(max(startFrame.height - (mouse.y - startMouse.y), ShelfPlacement.minimumSize.height), max(screenFrame.height, ShelfPlacement.minimumSize.height))
        // Screen coordinates are y-up: keep the top edge fixed by moving the origin as the height changes.
        window.setFrame(NSRect(x: startFrame.minX, y: startFrame.maxY - height, width: width, height: height), display: true)
    }
}

/// Shows and hides the floating shelf, places it, remembers where the user left it on each screen, and
/// keeps it on screen when displays change. The window exists only while it is shown or hidden after being
/// shown; `close()` releases it.
@MainActor
final class ShelfWindowController: NSObject, NSWindowDelegate {
    /// Where `show` puts the shelf.
    enum Placement {
        /// Centred on the pointer (a shake, or the wheel's Shelf action).
        case nearPoint(CGPoint)
        /// Where it last was on the screen under the pointer, else bottom centre (the menu bar tab).
        case remembered(screenPoint: CGPoint)
    }

    private let model: ShelfModel
    private let settings: ShelfSettings
    private var panel: ShelfPanel?
    private var saveTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    /// The user dropped files on the shelf.
    var onDrop: ([URL]) -> Void = { _ in }

    init(model: ShelfModel, settings: ShelfSettings) {
        self.model = model
        self.settings = settings
        super.init()
    }

    var isVisible: Bool { panel?.isVisible == true }

    func show(_ placement: Placement) {
        let panel = existingOrNewPanel()
        let point: CGPoint
        switch placement {
        case .nearPoint(let p), .remembered(let p): point = p
        }
        let screen = Self.screen(containing: point)
        let visible = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let saved = screen.flatMap(Self.key(for:)).flatMap { settings.lastFrame(forScreen: $0) }
        // Keep the size the user chose, never below the minimum.
        let size = CGSize(width: max(saved?.width ?? ShelfPlacement.defaultSize.width, ShelfPlacement.minimumSize.width),
                          height: max(saved?.height ?? ShelfPlacement.defaultSize.height, ShelfPlacement.minimumSize.height))
        let frame: CGRect
        switch placement {
        case .nearPoint:
            frame = ShelfPlacement.frame(size: size, centeredOn: point, in: visible)
        case .remembered:
            frame = saved.map { ShelfPlacement.restored(CGRect(origin: $0.origin, size: size), in: visible) }
                ?? ShelfPlacement.defaultFrame(size: size, in: visible)
        }
        model.refreshAvailability()
        applyLevel()
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        model.isShelfOpen = true
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        saveFrame()
        saveTask?.cancel()
        panel.orderOut(nil)
        model.isShelfOpen = false
        model.isDropTargeted = false
    }

    func toggle(_ placement: Placement) {
        if isVisible { hide() } else { show(placement) }
    }

    /// Re-reads `keepOnTop` (the setting changed while the shelf is up).
    func applyLevel() {
        panel?.level = settings.keepOnTop ? .floating : .normal
    }

    /// Releases the window and everything attached to it.
    func close() {
        saveTask?.cancel()
        saveTask = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        if let panel {
            if panel.isVisible { saveFrame() }
            panel.delegate = nil
            panel.orderOut(nil)
            panel.contentView = nil
            panel.close()
        }
        panel = nil
        model.isShelfOpen = false
        model.isDropTargeted = false
    }

    // MARK: Window

    private func existingOrNewPanel() -> ShelfPanel {
        if let panel { return panel }
        let content = ShelfContentView(model: model, close: { [weak self] in self?.hide() })
        content.onDrop = { [weak self] urls in self?.onDrop(urls) }
        let panel = ShelfPanel(content: content)
        panel.delegate = self
        self.panel = panel
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepOnScreen() }
        }
        return panel
    }

    /// A display was unplugged or rearranged: pull the shelf back onto a screen if it was left off one.
    private func keepOnScreen() {
        guard let panel, panel.isVisible else { return }
        let centre = CGPoint(x: panel.frame.midX, y: panel.frame.midY)
        let screen = Self.screen(containing: centre) ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let clamped = ShelfPlacement.clamped(panel.frame, in: visible)
        if clamped != panel.frame { panel.setFrame(clamped, display: true) }
    }

    nonisolated func windowDidMove(_ notification: Notification) {
        MainActor.assumeIsolated { scheduleSave() }
    }

    nonisolated func windowDidResize(_ notification: Notification) {
        MainActor.assumeIsolated { scheduleSave() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.saveFrame()
        }
    }

    private func saveFrame() {
        guard let panel, panel.isVisible,
              let screen = Self.screen(containing: CGPoint(x: panel.frame.midX, y: panel.frame.midY)),
              let key = Self.key(for: screen) else { return }
        settings.setLastFrame(panel.frame, forScreen: key)
    }

    // MARK: Screens

    private static func screen(containing point: CGPoint) -> NSScreen? {
        NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
    }

    private static func key(for screen: NSScreen) -> String? {
        DisplayIdentity.key(for: screen)
    }
}
