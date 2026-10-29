import AppKit
import OrbitCore
import SwiftUI

/// What dragging an entry out of the history carries.
enum ClipboardDragContent {
    /// A files entry's files that are still there, as file URLs.
    case files([URL])
    case text(String)
    case richText(rtf: Data, plain: String)
    /// An image entry as the temporary PNG written for it; `preview` is its thumbnail, if one is loaded.
    case imageFile(URL, preview: NSImage?)

    /// The operations a drag of this content offers: copy only. A history entry points at files the user copied,
    /// so dropping it on a Finder folder must copy them, never move the originals away (unlike the Shelf, which
    /// holds files to be moved).
    var allowedOperations: NSDragOperation { [.copy, .generic] }

    /// The dragging items for a drag that started at `point` in a view.
    func draggingItems(at point: NSPoint, flipped: Bool) -> [NSDraggingItem] {
        func single(_ writer: NSPasteboardWriting, image: NSImage) -> [NSDraggingItem] {
            let item = NSDraggingItem(pasteboardWriter: writer)
            item.setDraggingFrame(NSRect(x: point.x - image.size.width / 2, y: point.y - image.size.height / 2,
                                         width: image.size.width, height: image.size.height), contents: image)
            return [item]
        }
        switch self {
        case .files(let urls):
            let iconSize: CGFloat = 48
            return urls.enumerated().map { index, url in
                let item = NSDraggingItem(pasteboardWriter: url as NSURL)
                // A stack of icons for a few files, each a little off the last; the rest ride along without one.
                guard index < 6 else {
                    item.setDraggingFrame(NSRect(x: point.x, y: point.y, width: 1, height: 1), contents: nil)
                    return item
                }
                let icon = (NSWorkspace.shared.icon(forFile: url.path).copy() as? NSImage) ?? NSWorkspace.shared.icon(forFile: url.path)
                icon.size = NSSize(width: iconSize, height: iconSize)
                let offset = CGFloat(index) * 4
                item.setDraggingFrame(NSRect(x: point.x - iconSize / 2 + offset, y: point.y - iconSize / 2 + (flipped ? offset : -offset),
                                             width: iconSize, height: iconSize), contents: icon)
                return item
            }
        case .text(let text):
            return single(text as NSString, image: Self.label(text))
        case .richText(let rtf, let plain):
            let writer = NSPasteboardItem()
            writer.setData(rtf, forType: .rtf)
            writer.setString(plain, forType: .string)
            return single(writer, image: Self.label(plain))
        case .imageFile(let url, let preview):
            return single(url as NSURL, image: preview.map(Self.thumbnail) ?? Self.label("Image"))
        }
    }

    /// A small rounded label with the first words of `text`.
    private static func label(_ text: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]
        let preview = ClipboardItem.makePreview(String(text.prefix(400)))
        let string = (preview.count > 36 ? String(preview.prefix(36)) + "…" : preview) as NSString
        let size = string.size(withAttributes: attributes)
        return NSImage(size: NSSize(width: ceil(size.width) + 24, height: 28), flipped: false) { rect in
            NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).fill()
            NSColor.separatorColor.setStroke()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8).stroke()
            string.draw(at: NSPoint(x: 12, y: (rect.height - size.height) / 2), withAttributes: attributes)
            return true
        }
    }

    /// `image` shrunk to fit 96 points (a copy: the cached thumbnail is shared and must keep its size).
    private static func thumbnail(_ image: NSImage) -> NSImage {
        let scale = min(1, 96 / max(image.size.width, image.size.height, 1))
        let copy = (image.copy() as? NSImage) ?? image
        copy.size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return copy
    }
}

extension ClipboardModel {
    /// What dragging `item` out carries, built now (it reads the content and may write a temporary file).
    /// Nil for a copied password and for an entry whose content or files are gone.
    func dragContent(for item: ClipboardItem) -> ClipboardDragContent? {
        guard !item.concealed, let payload = payload(for: item) else { return nil }
        switch item.kind {
        case .text:
            return String(data: payload, encoding: .utf8).map { .text($0) }
        case .richText:
            return .richText(rtf: payload, plain: NSAttributedString(rtf: payload, documentAttributes: nil)?.string ?? item.preview)
        case .image:
            return exportedImageURL(for: item).map { .imageFile($0, preview: cachedThumbnail(for: item)) }
        case .files:
            let urls = (checkFiles(of: item)?.present ?? []).map { URL(fileURLWithPath: $0) }
            return urls.isEmpty ? nil : .files(urls)
        }
    }
}

/// A transparent AppKit view laid over the text and badge of a history row (not over its hover buttons,
/// which stay clickable). It is what lets a row be dragged out the way the Shelf's entries are, as an
/// `NSDraggingSession` that can carry several files and offer move, which SwiftUI's `onDrag` cannot. Because
/// it takes the mouse, it also does what the row's button did: a click chooses the entry. A right-click
/// shows the entry's menu; it reports hover (the popup selects the row under the pointer).
struct ClipboardRowSurface: NSViewRepresentable {
    var label: String
    var toolTip: String?
    var onClick: () -> Void
    var onHover: (Bool) -> Void = { _ in }
    /// Builds what a drag carries when one starts; nil means this entry can't be dragged.
    var dragContent: () -> ClipboardDragContent? = { nil }
    /// A drag ended with this result (`[]`: it was dropped nowhere).
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var menu: () -> [ClipboardMenuEntry] = { [] }
    var onMenuAction: (ClipboardEntryAction) -> Void = { _ in }

    func makeNSView(context: Context) -> ClipboardRowSurfaceView {
        let view = ClipboardRowSurfaceView()
        configure(view)
        return view
    }

    func updateNSView(_ view: ClipboardRowSurfaceView, context: Context) {
        configure(view)
    }

    private func configure(_ view: ClipboardRowSurfaceView) {
        view.label = label
        view.toolTip = toolTip
        view.onClick = onClick
        view.onHover = onHover
        view.dragContent = dragContent
        view.onDragEnded = onDragEnded
        view.menuEntries = menu
        view.onMenuAction = onMenuAction
    }
}

final class ClipboardRowSurfaceView: NSView, NSDraggingSource {
    var label = ""
    var onClick: () -> Void = {}
    var onHover: (Bool) -> Void = { _ in }
    var dragContent: () -> ClipboardDragContent? = { nil }
    var onDragEnded: (NSDragOperation) -> Void = { _ in }
    var menuEntries: () -> [ClipboardMenuEntry] = { [] }
    var onMenuAction: (ClipboardEntryAction) -> Void = { _ in }

    private var mouseDownEvent: NSEvent?
    private var movedFarEnough = false
    private var allowedOperations: NSDragOperation = [.copy]
    private var trackingArea: NSTrackingArea?

    override var isOpaque: Bool { false }
    // The window is not moved by a row; a mouse-down here belongs to the entry.
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        // `.activeAlways`: Orbit is an accessory app that is never active, and hover must still work.
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }

    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityLabel() -> String? { label }
    override func accessibilityPerformPress() -> Bool {
        onClick()
        return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        movedFarEnough = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !movedFarEnough, let down = mouseDownEvent else { return }
        let from = down.locationInWindow
        guard hypot(event.locationInWindow.x - from.x, event.locationInWindow.y - from.y) > 4 else { return }
        // Dragging is not clicking, even when there is nothing to carry (a copied password).
        movedFarEnough = true
        guard let content = dragContent() else { return }
        allowedOperations = content.allowedOperations
        let items = content.draggingItems(at: convert(down.locationInWindow, from: nil), flipped: isFlipped)
        beginDraggingSession(with: items, event: down, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownEvent = nil }
        guard mouseDownEvent != nil, !movedFarEnough, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onClick()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let entries = menuEntries()
        guard !entries.isEmpty else { return nil }
        let menu = NSMenu()
        // Items are enabled or not by the entries, not by whether a target answers.
        menu.autoenablesItems = false
        for entry in entries {
            switch entry {
            case .action(let action, let enabled):
                let item = ActionMenuItem(action: action) { [weak self] in self?.onMenuAction($0) }
                item.isEnabled = enabled
                menu.addItem(item)
            case .separator:
                menu.addItem(.separator())
            }
        }
        return menu
    }

    // MARK: Dragging

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        allowedOperations
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        mouseDownEvent = nil
        movedFarEnough = false
        onDragEnded(operation)
    }
}

private final class ActionMenuItem: NSMenuItem {
    private let entryAction: ClipboardEntryAction
    private let handler: (ClipboardEntryAction) -> Void

    init(action: ClipboardEntryAction, handler: @escaping (ClipboardEntryAction) -> Void) {
        entryAction = action
        self.handler = handler
        super.init(title: action.title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler(entryAction) }
}

/// Reports the pointer entering and leaving a whole tile, for its hover buttons. SwiftUI's `onHover` doesn't fire
/// for Orbit (an accessory app that is never active), and the row's `ClipboardRowSurface` covers only the text, so
/// it would report leaving as the pointer moves onto the buttons. Put it behind the tile: it takes no clicks.
struct ClipboardTileHover: NSViewRepresentable {
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> ClipboardTileHoverView {
        let view = ClipboardTileHoverView()
        view.onHover = onHover
        return view
    }

    func updateNSView(_ view: ClipboardTileHoverView, context: Context) {
        view.onHover = onHover
    }
}

final class ClipboardTileHoverView: NSView {
    var onHover: (Bool) -> Void = { _ in }
    private var trackingArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover(true) }
    override func mouseExited(with event: NSEvent) { onHover(false) }
}
