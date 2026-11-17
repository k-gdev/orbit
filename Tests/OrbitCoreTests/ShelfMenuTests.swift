import Testing
@testable import OrbitCore

/// What the right-click menu of a shelf entry offers.
@Suite struct ShelfMenuTests {
    /// The menu as a list of titles, with "-" for a separator.
    private static func titles(offline: Bool) -> [String] {
        ShelfMenuLayout.items(offline: offline).map { item in
            switch item {
            case .command(let command): return command.title
            case .separator: return "-"
            }
        }
    }

    @Test func aReachableItemCanBeMovedToTheTrash() {
        #expect(Self.titles(offline: false) == ["Open", "Show in Finder", "Copy Path", "Move to Trash", "-", "Remove from Shelf"])
    }

    @Test func anItemThatCannotBeReachedOffersOnlyWhatStillWorks() {
        // Trashing needs the file; it is not on offer for one that is dimmed.
        #expect(Self.titles(offline: true) == ["Copy Path", "-", "Remove from Shelf"])
    }

    @Test func removingFromTheShelfStaysLastAndApartFromTheFileCommands() {
        for offline in [false, true] {
            let items = ShelfMenuLayout.items(offline: offline)
            #expect(items.last == .command(.removeFromShelf))
            #expect(items.dropLast().last == .separator)
        }
    }
}
