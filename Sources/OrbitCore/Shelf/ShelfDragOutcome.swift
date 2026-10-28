import Foundation

/// What a finished drag out of the shelf means for the shelf. The shelf only holds references; when the
/// destination moved the files (Finder dropping onto a folder on the same volume) or deleted them (the
/// Trash in the Dock), they are no longer at the paths the shelf has, so they leave it. A copy, a link or
/// "open with" leaves them where they are.
public enum ShelfDragOutcome {
    /// `NSDragOperation.move` (the app asserts these match AppKit's values).
    public static let moveOperation: UInt = 16
    /// `NSDragOperation.delete`.
    public static let deleteOperation: UInt = 32

    /// Whether the drag's result (`NSDragOperation.rawValue`) removes the dragged files from the shelf.
    public static func removesFromShelf(operationRawValue: UInt) -> Bool {
        operationRawValue & (moveOperation | deleteOperation) != 0
    }
}
