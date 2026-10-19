import Foundation
import Testing
@testable import OrbitCore

@Suite final class ArchiveTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    static let weird = "-rf 'q\" ü.txt"

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func runner() -> JobRunner {
        let rootPath = root.path + "/"
        return JobRunner(
            processors: ProcessorRegistry.standard(capabilities: Fixtures.caps), capabilities: Fixtures.caps,
            fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
    }

    private func run(_ urls: [URL], _ action: SliceAction) async throws -> JobResult {
        try await runner().run(JobRequest(items: urls.map(DroppedItem.init(url:)), action: action), progress: { _ in })
    }

    private func file(_ name: String, _ text: String = "T") -> URL { Fixtures.file(name, text, in: root) }

    private func tree(_ files: [String: String], name: String = "tree") -> URL {
        Fixtures.tree(files, name: name, in: root)
    }

    @Test(arguments: [OutputFormat.zip, .tar, .tgz])
    func folderRoundTrip(f: OutputFormat) async throws {
        let folder = tree(["a.txt": "A", "sub/\(Self.weird)": "W"])
        let packed = try await run([folder], .convert(f)).outputs[0]
        #expect(packed.lastPathComponent == "tree.\(f.fileExtension)")
        let entries = try await Fixtures.archiveEntries(packed)
        #expect(Set(entries).isSuperset(of: ["tree/a.txt", "tree/sub/\(Self.weird)"]))
        let out = try await run([packed], .tool(.extract, nil)).outputs[0]
        #expect(try String(contentsOf: out.appending(path: "sub/\(Self.weird)"), encoding: .utf8) == "W")
        #expect(try String(contentsOf: out.appending(path: "a.txt"), encoding: .utf8) == "A")
    }

    @Test(arguments: [OutputFormat.zip, .tar, .tgz])
    func weirdLooseFileAtTopLevel(f: OutputFormat) async throws {
        let w = file(Self.weird, "W"), x = file("x.txt", "X")
        let packed = try await run([w, x], .action(.archive, .archive(f))).outputs[0]
        #expect(packed.lastPathComponent == "Archive.\(f.fileExtension)")
        #expect(Set(try await Fixtures.archiveEntries(packed)) == [Self.weird, "x.txt"])
        let out = try await run([packed], .tool(.extract, nil)).outputs[0]
        #expect(try String(contentsOf: out.appending(path: Self.weird), encoding: .utf8) == "W")
    }

    @Test func looseFilesArchive() async throws {
        let r = try await run([file("x.txt"), file("y.txt")], .action(.archive, .archive(.zip)))
        #expect(r.outputs[0].lastPathComponent == "Archive.zip")
        #expect(Set(try await Fixtures.archiveEntries(r.outputs[0])) == ["x.txt", "y.txt"])
    }

    @Test func singleFileKeepsItsName() async throws {
        let r = try await run([file("note.txt")], .convert(.zip))
        #expect(r.outputs[0].lastPathComponent == "note.txt.zip")
        let e = try await Fixtures.archiveEntries(r.outputs[0]); #expect(e == ["note.txt"], "\(e)")
    }

    @Test func sameNamedFilesFromDifferentFoldersDontCollide() async throws {
        let a = file("one/x.txt", "1"), b = file("two/x.txt", "2")
        let r = try await run([a, b], .action(.archive, .archive(.tar)))
        #expect(try await Fixtures.archiveEntries(r.outputs[0]).count == 2)
    }

    @Test func noDoubleNesting() async throws {
        let z = try await run([tree(["inner/a.txt": "A"], name: "box")], .convert(.zip)).outputs[0]
        // The source folder `box` still sits beside the archive, hence box-2.
        let out = try await run([z], .tool(.extract, nil)).outputs[0]
        #expect(out.lastPathComponent == "box-2")
        #expect(try String(contentsOf: out.appending(path: "inner/a.txt"), encoding: .utf8) == "A")
    }

    @Test func extractTwiceIsUnique() async throws {
        let z = try await run([file("x.txt"), file("y.txt")], .action(.archive, .archive(.zip))).outputs[0]
        #expect(try await run([z], .tool(.extract, nil)).outputs[0].lastPathComponent == "Archive")
        #expect(try await run([z], .tool(.extract, nil)).outputs[0].lastPathComponent == "Archive-2")
    }

    @Test func plainGz() async throws {
        let gz = Fixtures.gzipFile("hello", name: "note.txt.gz", in: root)
        let out = try await run([gz], .tool(.extract, nil)).outputs[0]
        #expect(out.lastPathComponent == "note.txt")
        #expect(try String(contentsOf: out, encoding: .utf8) == "hello")
    }

    @Test func repackZipToTgz() async throws {
        let z = try await run([tree(["a.txt": "A", "b.txt": "B"])], .convert(.zip)).outputs[0]
        let t = try await run([z], .convert(.tgz)).outputs[0]
        #expect(t.lastPathComponent.hasSuffix(".tar.gz"))
        #expect(Set(try await Fixtures.archiveEntries(t)).isSuperset(of: ["tree/a.txt", "tree/b.txt"]))
    }

    @Test func failureLeavesNoPartialOutput() async throws {
        let bad = file("broken.zip", "this is not a zip")
        await #expect(throws: (any Error).self) { try await self.run([bad], .tool(.extract, nil)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(Set(names) == ["fallback", "broken.zip"])
    }
}
