import AppKit
import SwiftUI

/// The borderless, transparent panel under Orbit's menu bar icon. Non-activating, so opening it never
/// pulls Orbit (or a window of Orbit's) to the front, but it can become key, so search fields in it take
/// typing. Escape asks `onCancel` to close it.
final class MenuBarPanel: NSPanel {
    var onCancel: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(origin: .zero, size: contentView.fittingSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        self.contentView = contentView
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        becomesKeyOnlyIfNeeded = false
        animationBehavior = .utilityWindow
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The controller places the panel itself (under the icon, inside the visible frame).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    /// ⌘X / ⌘C / ⌘V / ⌘A / ⌘Z / ⇧⌘Z in a search field: the panel never activates Orbit, so the main menu's
    /// Edit items may not see them (`EditMenu`). Everything else (the footer's ⌘, and ⌘Q) goes on as usual.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        EditMenu.perform(event, in: self) || super.performKeyEquivalent(with: event)
    }
}

/// Hosts `PanelView` and reports when its SwiftUI content changes size, so the panel can follow it.
final class PanelHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    required init(rootView: Content) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
