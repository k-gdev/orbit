import Foundation

/// What a finished drag out of the shelf means for the shelf. The shelf only holds references. When a drag
/// ends with a move or delete result (Finder dropping onto a folder on the same volume, the Trash in the
/// Dock) the files may have left their place, but the result arrives when the mouse is released, before
/// Finder has done anything: a cancelled "Replace" dialog or a failed move would leave the file where it
/// was. So the shelf looks again after `recheckDelay` and drops only what is really gone. A copy, a link or
/// "open with" needs no second look.
public enum ShelfDragOutcome {
    /// `NSDragOperation.move` (the app asserts these match AppKit's values).
    public static let moveOperation: UInt = 16
    /// `NSDragOperation.delete`.
    public static let deleteOperation: UInt = 32
    /// Seconds to wait after a move or delete result before checking whether the files are gone.
    public static let recheckDelay: TimeInterval = 1.5

    /// Whether the drag's result (`NSDragOperation.rawValue`) means the dragged files may have been moved or
    /// deleted, so they should be checked again shortly.
    public static func mayHaveMovedFiles(operationRawValue: UInt) -> Bool {
        operationRawValue & (moveOperation | deleteOperation) != 0
    }
}
