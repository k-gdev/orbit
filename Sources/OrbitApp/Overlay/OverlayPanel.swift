import AppKit
import OrbitCore

/// The borderless, transparent panel the wheel floats in. It never activates Orbit
/// and, unless `isInteractive`, never takes key or mouse events.
final class OverlayPanel: NSPanel {
    /// True only for the debug preview, where the panel takes the keyboard and mouse.
    var isInteractive = false {
        didSet {
            ignoresMouseEvents = !isInteractive
            acceptsMouseMovedEvents = isInteractive
        }
    }

    init() {
        let side = WheelGeometry.standard.panelSide
        super.init(contentRect: NSRect(x: 0, y: 0, width: side, height: side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { isInteractive }
    override var canBecomeMain: Bool { false }

    /// The wheel is placed by `WheelPlacement`; the panel's transparent margin may
    /// hang off the screen, so AppKit must not shift it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
