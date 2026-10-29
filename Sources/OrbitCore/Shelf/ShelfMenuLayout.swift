import Foundation

/// One command of a shelf entry's right-click menu.
public enum ShelfMenuCommand: Equatable, Sendable {
    case open, showInFinder, copyPath, moveToTrash, removeFromShelf

    public var title: String {
        switch self {
        case .open: return "Open"
        case .showInFinder: return "Show in Finder"
        case .copyPath: return "Copy Path"
        case .moveToTrash: return "Move to Trash"
        case .removeFromShelf: return "Remove from Shelf"
        }
    }
}

/// One line of the menu.
public enum ShelfMenuItem: Equatable, Sendable {
    case command(ShelfMenuCommand)
    case separator
}

/// What a shelf entry's right-click menu offers, decided apart from the views so it can be tested. An item that
/// can't be reached right now (`offline`) offers only what still works without the file: Open, Show in Finder
/// and Move to Trash all need it. "Remove from Shelf" comes last, apart from the commands that act on the file.
public enum ShelfMenuLayout {
    public static func items(offline: Bool) -> [ShelfMenuItem] {
        if offline { return [.command(.copyPath), .separator, .command(.removeFromShelf)] }
        return [
            .command(.open),
            .command(.showInFinder),
            .command(.copyPath),
            .command(.moveToTrash),
            .separator,
            .command(.removeFromShelf),
        ]
    }
}
