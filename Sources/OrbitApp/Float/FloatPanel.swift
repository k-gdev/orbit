import AppKit

/// A small always-on-top tile for one or more files: a 96x96 thumbnail with a count badge.
/// Hover brings it to full opacity and shows a close button, the name is the tooltip, a
/// click opens Quick Look, and dragging it out drags the files (copy) into another app.
final class FloatPanel: NSPanel {
    static let side: CGFloat = 96
    static let restingAlpha: CGFloat = 0.85

    var onClose: (() -> Void)?
    var onPreview: (([URL]) -> Void)?
    let urls: [URL]

    init(urls: [URL]) {
        self.urls = urls
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.side, height: Self.side),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        alphaValue = Self.restingAlpha
        let tile = FloatTileView(urls: urls)
        tile.panel = self
        contentView = tile
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    override func close() {
        super.close()
        onClose?()
        onClose = nil
    }
}

private final class FloatTileView: NSView, NSDraggingSource {
    weak var panel: FloatPanel?
    private let urls: [URL]
    private let imageView = NSImageView()
    private let closeButton = NSButton()
    private let badge = NSTextField(labelWithString: "")
    private var mouseDownPoint: NSPoint?
    private var dragging = false

    init(urls: [URL]) {
        self.urls = urls
        super.init(frame: NSRect(x: 0, y: 0, width: FloatPanel.side, height: FloatPanel.side))
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.9).cgColor
        toolTip = urls.map(\.lastPathComponent).joined(separator: "\n")

        imageView.frame = bounds.insetBy(dx: 6, dy: 6)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.image = NSWorkspace.shared.icon(forFile: urls[0].path)
        addSubview(imageView)
        let first = urls[0]
        Task { @MainActor [weak self] in
            if let image = await Thumbnails.image(for: first, size: CGSize(width: FloatPanel.side, height: FloatPanel.side)) {
                self?.imageView.image = image
            }
        }

        if urls.count > 1 {
            badge.stringValue = "\(urls.count)"
            badge.font = .systemFont(ofSize: 11, weight: .bold)
            badge.textColor = .white
            badge.alignment = .center
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor(OrbitTheme.accent).cgColor
            badge.layer?.cornerRadius = 9
            let width = max(18, badge.intrinsicContentSize.width + 10)
            badge.frame = NSRect(x: bounds.maxX - width - 4, y: 4, width: width, height: 18)
            addSubview(badge)
        }

        closeButton.bezelStyle = .circular
        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Close")
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.target = self
        closeButton.action = #selector(closeFloat)
        closeButton.frame = NSRect(x: 2, y: bounds.maxY - 22, width: 20, height: 20)
        closeButton.isHidden = true
        addSubview(closeButton)

        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func closeFloat() { panel?.close() }

    override func mouseEntered(with event: NSEvent) {
        panel?.alphaValue = 1
        closeButton.isHidden = false
    }

    override func mouseExited(with event: NSEvent) {
        if !dragging { panel?.alphaValue = FloatPanel.restingAlpha }
        closeButton.isHidden = true
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownPoint else { return }
        let here = event.locationInWindow
        guard hypot(here.x - start.x, here.y - start.y) > 4 else { return }
        dragging = true
        let image = imageView.image ?? NSWorkspace.shared.icon(forFile: urls[0].path)
        let items = urls.map { url -> NSDraggingItem in
            let item = NSDraggingItem(pasteboardWriter: url as NSURL)
            item.setDraggingFrame(bounds, contents: image)
            return item
        }
        beginDraggingSession(with: items, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !dragging, mouseDownPoint != nil else { return }
        panel?.onPreview?(urls)
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        if operation != [] {
            panel?.close()
        } else {
            panel?.alphaValue = FloatPanel.restingAlpha
        }
    }
}
