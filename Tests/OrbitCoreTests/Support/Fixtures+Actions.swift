import Foundation
@testable import OrbitCore

extension Fixtures {
    /// A source folder and an empty destination folder under `root`.
    static func actionFolders(in root: URL) -> (source: URL, dest: URL) {
        let source = root.appending(path: "src", directoryHint: .isDirectory)
        let dest = root.appending(path: "dest", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("Fixtures.actionFolders: \(error)")
        }
        return (source, dest)
    }
}
