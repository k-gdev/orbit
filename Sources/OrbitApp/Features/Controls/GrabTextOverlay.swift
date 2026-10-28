import AppKit
import OrbitCore

/// The area the user dragged out: which display, and the rectangle on it in points with the origin at
/// the display's top left (ScreenCaptureKit's `sourceRect` convention).
struct GrabTextSelection {
    let displayID: CGDirectDisplayID
    let rect: CGRect
}

/// Grab Text's crosshair (spec §8.4): one borderless, slightly dimmed window per display. Drag a
/// rectangle on any of them; releasing the mouse finishes, Esc (or a click without a drag, or switching
/// away from Orbit) cancels. The windows close before `completion` runs.
@MainActor
final class GrabTextOverlay {
    private var windows: [GrabTextOverlayWindow] = []
    private var completion: ((GrabTextSelection?) -> Void)?
    private var resignObserver: NSObjectProtocol?

    var isShowing: Bool { !windows.isEmpty }

    func show(completion: @escaping (GrabTextSelection?) -> Void) {
        guard windows.isEmpty else { return }
        self.completion = completion
        let mouse = NSEvent.mouseLocation
        for screen in NSScreen.screens {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { continue }
            let window = GrabTextOverlayWindow(screen: screen, displayID: CGDirectDisplayID(number.uint32Value)) { [weak self] selection in
                self?.finish(selection)
            }
            windows.append(window)
        }
        guard !windows.isEmpty else { completion(nil); self.completion = nil; return }
        NSApp.activate(ignoringOtherApps: true)
        for window in windows { window.orderFrontRegardless() }
        let underMouse = windows.first { NSMouseInRect(mouse, $0.frame, false) } ?? windows[0]
        underMouse.makeKey()
        NSCursor.crosshair.set()
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.finish(nil) }
        }
    }

    /// Closes the overlay without a selection (the feature stopping, or Esc).
    func cancel() { finish(nil) }

    private func finish(_ selection: GrabTextSelection?) {
        guard let completion else { return }
        self.completion = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        for window in windows { window.orderOut(nil); window.close() }
        windows.removeAll()
        NSCursor.arrow.set()
        completion(selection)
    }
}

/// One display's overlay window. Esc reaches it whichever view is first responder.
final class GrabTextOverlayWindow: NSWindow {
    private let onFinish: (GrabTextSelection?) -> Void

    init(screen: NSScreen, displayID: CGDirectDisplayID, onFinish: @escaping (GrabTextSelection?) -> Void) {
        self.onFinish = onFinish
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        isReleasedWhenClosed = false
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let view = GrabTextSelectionView(displayID: displayID, screenHeight: screen.frame.height, onFinish: onFinish)
        contentView = view
        initialFirstResponder = view
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func becomeKey() {
        super.becomeKey()
        makeFirstResponder(contentView)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }   // Esc
    }

    override func cancelOperation(_ sender: Any?) { onFinish(nil) }
}

/// Draws the dim veil with the selection cut out and tracks the drag.
private final class GrabTextSelectionView: NSView {
    private let displayID: CGDirectDisplayID
    private let screenHeight: CGFloat
    private let onFinish: (GrabTextSelection?) -> Void
    private var origin: CGPoint?
    private var current: CGPoint?

    /// Smaller than this (in points) counts as a click, which cancels.
    private static let minimumSide: CGFloat = 4

    init(displayID: CGDirectDisplayID, screenHeight: CGFloat, onFinish: @escaping (GrabTextSelection?) -> Void) {
        self.displayID = displayID
        self.screenHeight = screenHeight
        self.onFinish = onFinish
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.cursorUpdate, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    private var selection: CGRect? {
        guard let origin, let current else { return nil }
        return CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
                      width: abs(current.x - origin.x), height: abs(current.y - origin.y)).intersection(bounds)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        origin = convert(event.locationInWindow, from: nil)
        current = origin
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard origin != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard origin != nil else { return }
        current = convert(event.locationInWindow, from: nil)
        guard let rect = selection, rect.width >= Self.minimumSide, rect.height >= Self.minimumSide else {
            onFinish(nil)
            return
        }
        // View coordinates have the origin at the bottom left; ScreenCaptureKit wants top left.
        let flipped = CGRect(x: rect.minX, y: screenHeight - rect.maxY, width: rect.width, height: rect.height)
        onFinish(GrabTextSelection(displayID: displayID, rect: flipped.integral))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onFinish(nil) } else { super.keyDown(with: event) }   // Esc
    }

    override func cancelOperation(_ sender: Any?) { onFinish(nil) }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.22).setFill()
        bounds.fill()
        guard let rect = selection, rect.width > 0, rect.height > 0 else { return }
        NSColor.clear.setFill()
        rect.fill(using: .copy)
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5))
        border.lineWidth = 1
        NSColor.white.withAlphaComponent(0.95).setStroke()
        border.stroke()
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let badge = CGRect(x: rect.maxX - size.width - 10, y: max(rect.minY - size.height - 10, 4),
                           width: size.width + 10, height: size.height + 4)
        NSColor.black.withAlphaComponent(0.6).setFill()
        NSBezierPath(roundedRect: badge, xRadius: 4, yRadius: 4).fill()
        label.draw(at: CGPoint(x: badge.minX + 5, y: badge.minY + 2), withAttributes: attributes)
    }
}
