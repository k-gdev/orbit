import AppKit
import OrbitCore

/// The overlay panel's content view: hosts the wheel and is the drop target for file
/// URLs. Dragging over it moves the highlight; dropping on a slice runs that slice.
/// The hub and empty space refuse the drop, so dropping there does nothing.
final class DropTargetView: NSView {
    weak var wheel: WheelController?
    private var didPerform = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The whole overlay is the drop target, whatever views the hosted wheel contains.
    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        didPerform = false
        let operation = update(sender)
        log("draggingEntered -> \(Self.describe(operation))")
        return operation
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        wheel?.model.resetPointer()
        log("draggingExited")
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let wheel, let slice = wheel.model.selectedSlice else { return false }
        let urls = sender.draggingPasteboard.droppedFileURLs
        guard !urls.isEmpty else { return false }
        let known = wheel.model.items
        let items = urls == known.map(\.url) ? known : urls.map(DroppedItem.init(url:))
        didPerform = true
        Log.info("drop: \(slice.id) on \(items.count) item(s)")
        // Run the slice once the drag session has finished: an editor may open a modal
        // panel, which must not keep the drag source waiting.
        DispatchQueue.main.async { [weak wheel] in
            guard let wheel else { return }
            wheel.hide()
            wheel.onSelect?(slice, items)
        }
        return true
    }

    /// Esc, or a refused drop on the hub or empty space.
    override func draggingEnded(_ sender: any NSDraggingInfo) {
        guard !didPerform else {
            didPerform = false
            return
        }
        log("draggingEnded without a drop")
        guard let wheel, wheel.isVisible else { return }
        wheel.hide()
        wheel.onCancel?()
    }

    /// Moves the highlight to the pointer and says whether a drop here would run a slice.
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let wheel, let window else { return [] }
        let screenPoint = window.convertPoint(toScreen: sender.draggingLocation)
        wheel.model.updatePointer(offset: wheel.offset(of: screenPoint))
        guard wheel.model.selectedSlice != nil else { return [] }
        return Self.operation(allowedBy: sender.draggingSourceOperationMask)
    }

    /// `.copy`, since Orbit only reads the dragged files. Holding ⌘ or Control (default
    /// triggers) filters the source's mask to `.generic` or `.link`, so fall back to those
    /// rather than refuse the drop. Never `.move`: some sources finish a move by deleting.
    static func operation(allowedBy mask: NSDragOperation) -> NSDragOperation {
        [NSDragOperation.copy, .generic, .link].first(where: mask.contains) ?? []
    }

    private static func describe(_ operation: NSDragOperation) -> String {
        if operation.contains(.copy) { return "copy" }
        if operation.contains(.generic) { return "generic" }
        if operation.contains(.link) { return "link" }
        return operation.isEmpty ? "none" : "raw \(operation.rawValue)"
    }

    private func log(_ message: @autoclosure () -> String) {
        guard wheel?.logsDropEvents == true else { return }
        Log.info("drop: \(message())")
    }
}

extension NSPasteboard {
    /// File URLs on the pasteboard as plain path URLs (Finder may write file-reference
    /// URLs, `file:///.file/id=…`, whose path components aren't the file's name).
    var droppedFileURLs: [URL] {
        let objects = readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { ($0 as? NSURL)?.filePathURL }
    }
}
