import Foundation
import Testing
@testable import OrbitCore

@Suite final class ActionTests {
    let root = Fixtures.tempDir()
    let src: URL
    let dest: URL
    struct Boom: Error {}

    init() {
        (src, dest) = Fixtures.actionFolders(in: root)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func run(_ urls: [URL], _ action: SliceAction, parameters: ToolParameters = .none) async throws -> JobResult {
        let rootPath = root.path + "/"
        let runner = JobRunner(
            processors: ProcessorRegistry.standard(capabilities: Fixtures.caps), capabilities: Fixtures.caps,
            fallbackFolder: root.appending(path: "fallback", directoryHint: .isDirectory),
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
        return try await runner.run(JobRequest(items: urls.map(DroppedItem.init(url:)), action: action, parameters: parameters),
                                    progress: { _ in })
    }

    @Test func pathTextPOSIX() {
        #expect(FileActions.pathText([URL(filePath: "/a/b.png"), URL(filePath: "/a/c d.png")], style: .posix) == "/a/b.png\n/a/c d.png")
    }

    @Test func pathTextURI() {
        #expect(FileActions.pathText([URL(filePath: "/Users/k/My File.png")], style: .uri) == "file:///Users/k/My%20File.png")
    }

    @Test func copyCollision() throws {
        let a = Fixtures.file("a.txt", "one", in: src)
        _ = Fixtures.file("a.txt", "existing", in: dest)
        let out = try FileActions.copy([a], to: dest)
        #expect(out[0].lastPathComponent == "a-2.txt")
        #expect(exists(a))
        #expect(try String(contentsOf: out[0], encoding: .utf8) == "one")
    }

    @Test func terminalDir() throws {
        let file = Fixtures.file("a.txt", "x", in: src)
        #expect(FileActions.terminalDirectory(for: file) == src)
        #expect(FileActions.terminalDirectory(for: src) == src)
    }

    @Test func copyPathJob() async throws {
        let a = Fixtures.file("a.txt", "x", in: src)
        let b = Fixtures.file("b b.txt", "x", in: src)
        let one = try await run([a], .action(.copyPath, .pathStyle(.posix)))
        #expect(one.clipboardText == a.path)
        #expect(one.summary == "Copied path")
        #expect(one.outputs.isEmpty)
        let two = try await run([a, b], .action(.copyPath, .pathStyle(.uri)))
        #expect(two.clipboardText == "\(a.absoluteString)\n\(b.absoluteString)")
        #expect(two.summary == "Copied 2 paths")
    }

    @Test func copyToJobAndUndo() async throws {
        let a = Fixtures.file("a.txt", "one", in: src)
        _ = Fixtures.file("a.txt", "existing", in: dest)
        let r = try await run([a], .action(.copyTo, .folder(dest)))
        #expect(r.outputs.map(\.lastPathComponent) == ["a-2.txt"])
        #expect(exists(a))
        #expect(r.undo == .trash(r.outputs))
        try UndoPerformer.perform(try #require(r.undo), trash: { try FileManager.default.removeItem(at: $0) })
        #expect(!exists(dest.appending(path: "a-2.txt")))
        #expect(exists(dest.appending(path: "a.txt")))
    }

    @Test func folderFromParameters() async throws {
        let a = Fixtures.file("a.txt", "one", in: src)
        let r = try await run([a], .action(.copyTo, nil), parameters: .folder(dest))
        #expect(r.outputs.map(\.lastPathComponent) == ["a.txt"])
        #expect(exists(dest.appending(path: "a.txt")))
    }

    @Test func moveAndUndo() async throws {
        let a = Fixtures.file("a.txt", "one", in: src)
        let r = try await run([a], .action(.moveTo, .folder(dest)))
        #expect(!exists(a) && exists(dest.appending(path: "a.txt")))
        try UndoPerformer.perform(try #require(r.undo))
        #expect(exists(a) && !exists(dest.appending(path: "a.txt")))
    }

    @Test func moveIntoSameFolder() async throws {
        let a = Fixtures.file("a.txt", "one", in: src)
        await #expect(throws: OrbitError.unsupported("Already in \(src.lastPathComponent).")) {
            _ = try await self.run([a], .action(.moveTo, .folder(self.src)))
        }
        #expect(exists(a))
    }

    @Test func moveFolderIntoItselfRefused() throws {
        let inner = src.appending(path: "inner", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        #expect(throws: OrbitError.self) { _ = try FileActions.move([src], to: inner) }
        #expect(exists(inner))
    }

    @Test func moveRollsBackOnFailure() throws {
        let a = Fixtures.file("a.txt", "1", in: src)
        let b = Fixtures.file("b.txt", "2", in: src)
        var calls = 0
        #expect(throws: Boom.self) {
            _ = try FileActions.move([a, b], to: dest, check: {
                calls += 1
                if calls == 2 { throw Boom() }
            })
        }
        #expect(exists(a) && exists(b))
        #expect(!exists(dest.appending(path: "a.txt")))
    }

    @Test func copyRollsBackOnFailure() throws {
        let a = Fixtures.file("a.txt", "1", in: src)
        let b = Fixtures.file("b.txt", "2", in: src)
        var calls = 0
        #expect(throws: Boom.self) {
            _ = try FileActions.copy([a, b], to: dest, check: {
                calls += 1
                if calls == 2 { throw Boom() }
            })
        }
        #expect(exists(a) && exists(b))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dest.path).isEmpty)
    }

    @Test func combiningMoveKeepsEveryItemInOneUnit() async throws {
        let a = Fixtures.file("a.txt", "1", in: src)
        let b = Fixtures.file("b.txt", "2", in: src)
        let r = try await run([a, b], .action(.moveTo, .folder(dest)))
        #expect(r.outputs.count == 2)
        #expect(r.undo != nil)
    }
}
