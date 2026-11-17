import AppKit
import SwiftUI

/// A borderless, non-activating panel for progress and result HUDs. It floats above
/// other windows, takes mouse clicks without activating Orbit, and reports hover.
final class HUDPanel: NSPanel {
    private let host: HoverHostingView

    init<Content: View>(rootView: Content, onHover: ((Bool) -> Void)? = nil) {
        host = HoverHostingView(rootView: AnyView(rootView))
        host.onHover = onHover
        let size = host.fittingSize
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentView = host
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = GlassRendering.windowHasShadow
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// HUDs are placed by their controllers and may sit anywhere on screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Re-measures the content (its text may have changed) and keeps the top-left corner.
    func fitToContent() {
        let size = host.fittingSize
        guard size != frame.size else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - size.height, width: size.width, height: size.height), display: true)
    }
}

private final class HoverHostingView: NSHostingView<AnyView> {
    var onHover: ((Bool) -> Void)?
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let new = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(new)
        area = new
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

enum HUDPlacement {
    /// The screen holding `point` (or the main screen), as its visible frame.
    static func visibleFrame(containing point: CGPoint) -> CGRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
    }

    static func clamp(_ frame: CGRect, to bounds: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.origin.x, bounds.minX + 8), max(bounds.minX + 8, bounds.maxX - f.width - 8))
        f.origin.y = min(max(f.origin.y, bounds.minY + 8), max(bounds.minY + 8, bounds.maxY - f.height - 8))
        return f
    }
}
