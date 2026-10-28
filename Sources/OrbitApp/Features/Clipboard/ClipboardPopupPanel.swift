import AppKit
import OrbitCore
import SwiftUI

/// The popup's window: borderless, transparent and non-activating (opening it never pulls Orbit to the
/// front, so the app you were typing in stays the active one), but able to become key so the search
/// field takes typing. If the search field doesn't hold focus (the user clicked a row), the arrow,
/// Return and Esc keys still reach `onKey`.
final class ClipboardPopupPanel: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    var onResignKey: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.contentView = contentView
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The controller places the panel itself, inside the visible frame of the pointer's screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func keyDown(with event: NSEvent) {
        if onKey?(event) != true { super.keyDown(with: event) }
    }
}

/// Opens the popup at the pointer and closes it. It only shows the history; what choosing an entry
/// does (write the pasteboard, bring the previous app back, press ⌘V) is the owner's `onChoose`.
///
/// Everything it creates (the window, the mouse monitor) exists only while the popup is up; `hide`
/// releases all of it.
@MainActor
final class ClipboardPopupController {
    private let model: ClipboardModel
    private let state = ClipboardPopupState()
    private var panel: ClipboardPopupPanel?
    private var mouseMonitor: Any?
    private var isHiding = false
    /// The popup's top-left corner, kept while its height changes with the number of matches.
    private var anchor = NSPoint.zero

    /// The app that was in front when the popup opened (nil when that was Orbit itself).
    private(set) var previousApp: NSRunningApplication?

    /// An entry was chosen (Return or a click). The popup is already closed.
    var onChoose: (ClipboardItem, NSRunningApplication?) -> Void = { _, _ in }
    /// Whether choosing will also paste (shown in the hint line).
    var willPaste: () -> Bool = { false }

    init(model: ClipboardModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible == true }

    /// Opens the popup with its top-left corner near `pointer` (AppKit screen coordinates).
    func show(at pointer: NSPoint) {
        guard panel == nil else { return }
        model.loadIfNeeded()
        model.enforceLimits()
        state.reset(history: model.history)

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let view = ClipboardPopupView(state: state, model: model, verb: willPaste() ? "paste" : "copy",
                                      choose: { [weak self] in self?.choose($0) },
                                      cancel: { [weak self] in self?.hide(restoreFocus: true) })
        let host = PanelHostingView(rootView: view)
        host.onSizeChange = { [weak self] in self?.resize() }
        let panel = ClipboardPopupPanel(contentView: host)
        panel.onResignKey = { [weak self] in self?.hide(restoreFocus: false) }
        panel.onKey = { [weak self] event in self?.handleKey(event) ?? false }
        self.panel = panel

        let size = host.fittingSize
        let bounds = HUDPlacement.visibleFrame(containing: pointer)
        let placed = HUDPlacement.clamp(CGRect(x: pointer.x - 18, y: pointer.y - size.height + 10, width: size.width, height: size.height), to: bounds)
        panel.setFrame(placed, display: false)
        anchor = NSPoint(x: placed.minX, y: placed.maxY)

        panel.orderFrontRegardless()
        panel.makeKey()
        installMouseMonitor()
    }

    /// Closes the popup and releases its window. With `restoreFocus`, the app that was in front before
    /// is made the active one again (a no-op unless something took the front meanwhile).
    func hide(restoreFocus: Bool) {
        guard let panel, !isHiding else { return }
        isHiding = true
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        panel.onResignKey = nil
        panel.onKey = nil
        panel.orderOut(nil)
        panel.contentView = nil
        panel.close()
        self.panel = nil
        isHiding = false
        if restoreFocus, let app = previousApp {
            Task { await PasteInjector.bringToFront(app) }
        }
    }

    private func choose(_ item: ClipboardItem) {
        let app = previousApp
        hide(restoreFocus: false)
        onChoose(item, app)
    }

    /// Arrow keys, Return and Esc for when the search field isn't the first responder.
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 126: state.move(by: -1)                                   // up
        case 125: state.move(by: 1)                                    // down
        case 36, 76: if let item = state.selected { choose(item) }     // return, keypad enter
        case 53: hide(restoreFocus: true)                              // esc
        default: return false
        }
        return true
    }

    /// A click outside the popup (in any other app's window) closes it. Mouse events need no permission.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] _ in
            DispatchQueue.main.async { self?.hide(restoreFocus: false) }
        }
    }

    /// The content changed height (fewer matches): keep the top-left corner where it was.
    private func resize() {
        guard let panel, let host = panel.contentView else { return }
        let size = host.fittingSize
        guard size.width > 1, size.height > 1, size != panel.frame.size else { return }
        let bounds = HUDPlacement.visibleFrame(containing: NSPoint(x: anchor.x, y: anchor.y - 1))
        let frame = HUDPlacement.clamp(CGRect(x: anchor.x, y: anchor.y - size.height, width: size.width, height: size.height), to: bounds)
        panel.setFrame(frame, display: true)
    }
}
