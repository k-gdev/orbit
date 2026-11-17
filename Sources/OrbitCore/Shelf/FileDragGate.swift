import Foundation

/// Decides whether a mouse drag in progress is a drag of files. The drag pasteboard keeps whatever the
/// last drag put on it, so "it holds file URLs" is also true while the mouse is dragging something else
/// (selecting text, resizing a window). A file drag is one where the pasteboard's change count moved after
/// the button went down (the source wrote it when the drag began) and it holds file URLs, the same rule
/// the wheel's trigger uses. The shelf's shake watcher counts only samples for which this is true.
public struct FileDragGate: Sendable {
    private var baselineChangeCount: Int?

    public init() {}

    /// The left button went down with the drag pasteboard at `changeCount`.
    public mutating func buttonDown(changeCount: Int) {
        baselineChangeCount = changeCount
    }

    /// The left button went up.
    public mutating func buttonUp() {
        baselineChangeCount = nil
    }

    /// True while the button is down and a drag that began after it carries file URLs.
    public func isFileDrag(changeCount: Int, hasFiles: Bool) -> Bool {
        guard let baselineChangeCount else { return false }
        return hasFiles && changeCount != baselineChangeCount
    }
}
