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

    // MARK: Hostile archives
    // Archiver.unpack relies on the safe defaults of bsdtar and ditto (they refuse `../` and absolute
    // entries and do not follow symlinks planted by the archive). These tests pin that behaviour.

    /// A sandbox shaped like a job: `base/jobs/temp` is the temp directory, and `base` must stay
    /// free of anything but `jobs`, with `root` unchanged, after a hostile archive is unpacked.
    private func unpackHostile(_ build: (URL, URL) -> URL, ext: String, abs: URL) async -> (unpacked: [String]?, base: URL, before: Set<String>) {
        let base = root.appending(path: "sandbox-\(UUID().uuidString)", directoryHint: .isDirectory)
        let temp = base.appending(path: "jobs/temp", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let archive = build(base, abs)
        let before = Set((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
        let unpacked = try? await Archiver.unpack(DroppedItem(url: archive), temp: temp)
        return (unpacked?.items.map(\.lastPathComponent), base, before)
    }

    private func assertContained(_ r: (unpacked: [String]?, base: URL, before: Set<String>), abs: URL, sourceLocation: SourceLocation = #_sourceLocation) {
        let fm = FileManager.default
        let baseKids = Set((try? fm.contentsOfDirectory(atPath: r.base.path)) ?? [])
        #expect(baseKids.subtracting(["jobs", "hostile"]).isEmpty, "escaped into base: \(baseKids)", sourceLocation: sourceLocation)
        #expect(Set((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).subtracting(r.before).isEmpty,
                "escaped into the folder above base", sourceLocation: sourceLocation)
        #expect(!fm.fileExists(atPath: abs.path), "absolute entry was written", sourceLocation: sourceLocation)
        let jobsKids = (try? fm.contentsOfDirectory(atPath: r.base.appending(path: "jobs").path)) ?? []
        #expect(jobsKids == ["temp"], "escaped into jobs: \(jobsKids)", sourceLocation: sourceLocation)
    }

    @Test func zipWithDotDotAndAbsoluteEntriesStaysInside() async throws {
        let abs = root.appending(path: "abs-zip-\(UUID().uuidString).txt")
        let r = await unpackHostile({ base, abs in
            let a = base.deletingLastPathComponent().appending(path: "hostile-\(UUID().uuidString).zip")
            Fixtures.hostileZip([("ok.txt", "ok"), ("../../../escape-up.txt", "x"), ("../../../../escape-up2.txt", "x"),
                                 (abs.path, "x")], at: a)
            return a
        }, ext: "zip", abs: abs)
        assertContained(r, abs: abs)
        try? FileManager.default.removeItem(at: abs)
    }

    @Test func tarWithDotDotAbsoluteAndSymlinkEntriesStaysInside() async throws {
        let abs = root.appending(path: "abs-tar-\(UUID().uuidString).txt")
        let outside = root.appending(path: "outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let r = await unpackHostile({ base, abs in
            let a = base.deletingLastPathComponent().appending(path: "hostile-\(UUID().uuidString).tar")
            Fixtures.hostileTar([
                .init(name: "ok.txt", link: nil, data: "ok"),
                .init(name: "../../../escape-up.txt", link: nil, data: "x"),
                .init(name: abs.path, link: nil, data: "x"),
                .init(name: "link", link: outside.path, data: ""),
                .init(name: "link/through.txt", link: nil, data: "x"),
                .init(name: "uplink", link: "../../..", data: ""),
                .init(name: "uplink/through2.txt", link: nil, data: "x"),
            ], at: a)
            return a
        }, ext: "tar", abs: abs)
        assertContained(r, abs: abs)
        #expect((try FileManager.default.contentsOfDirectory(atPath: outside.path)).isEmpty,
                "a file was written through a symlink")
        try? FileManager.default.removeItem(at: abs)
        try? FileManager.default.removeItem(at: outside)
    }

    // MARK: Symlinks are stored as links, never followed

    /// A folder outside the archive holding a "secret", for the link tests below.
    private func secretFolder() throws -> URL {
        let outside = root.appending(path: "outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        _ = Fixtures.file("id_rsa", "SECRET", in: outside)
        return outside
    }

    private func verboseListing(_ archive: URL) async throws -> String {
        try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tvf", archive.path]).stdout
    }

    @Test func repackSingleAbsoluteSymlinkKeepsTheLink() async throws {
        let outside = try secretFolder()
        let tarURL = root.appending(path: "photos.tar")
        Fixtures.hostileTar([.init(name: "photos", link: outside.path, data: "")], at: tarURL)
        let zip = try await run([tarURL], .convert(.zip)).outputs[0]
        let entries = try await Fixtures.archiveEntries(zip)
        #expect(entries == ["photos"], "\(entries)")
        #expect(!entries.contains { $0.contains("id_rsa") })
        #expect(try await verboseListing(zip).hasPrefix("l"), "photos should be stored as a link")
    }

    @Test(arguments: [OutputFormat.zip, .tar, .tgz])
    func archivingASymlinkStoresTheLink(f: OutputFormat) async throws {
        let outside = try secretFolder()
        let link = root.appending(path: "photos")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let packed = try await run([link], .action(.archive, .archive(f))).outputs[0]
        let entries = try await Fixtures.archiveEntries(packed)
        #expect(entries == ["photos"], "\(entries)")
        #expect(try await verboseListing(packed).hasPrefix("l"), "photos should be stored as a link")
    }

    @Test func multiItemExtractLeavesMacOSXBehind() async throws {
        let tarURL = root.appending(path: "two.tar")
        Fixtures.hostileTar([.init(name: "a.txt", link: nil, data: "A"), .init(name: "b.txt", link: nil, data: "B"),
                             .init(name: "__MACOSX/notes.txt", link: nil, data: "junk")], at: tarURL)
        let out = try await run([tarURL], .tool(.extract, nil)).outputs[0]
        #expect(try FileManager.default.contentsOfDirectory(atPath: out.path).sorted() == ["a.txt", "b.txt"])
    }
}
