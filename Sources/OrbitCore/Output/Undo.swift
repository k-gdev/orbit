import Foundation

public struct FileMove: Sendable, Equatable {
    public let from: URL
    public let to: URL
    public init(from: URL, to: URL) { self.from = from; self.to = to }
}

public enum UndoRecord: Sendable, Equatable {
    case trash([URL])
    case moveBack([FileMove])
}

public enum UndoPerformer {
    public static func perform(
        _ r: UndoRecord,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) throws {
        switch r {
        case .trash(let urls):
            for url in urls { try trash(url) }
        case .moveBack(let moves):
            let fm = FileManager.default
            for move in moves {
                var target = move.from
                if fm.fileExists(atPath: target.path) {
                    target = OutputNamer.uniqueURL(
                        in: move.from.deletingLastPathComponent(),
                        base: OutputNamer.stem(of: move.from),
                        ext: OutputNamer.fullExtension(of: move.from),
                        exists: { fm.fileExists(atPath: $0.path) }
                    )
                }
                try fm.moveItem(at: move.to, to: target)
            }
        }
    }
}
