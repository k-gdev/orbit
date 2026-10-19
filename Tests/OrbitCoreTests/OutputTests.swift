import Foundation
import Testing
@testable import OrbitCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "orbit-out-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@Test func suffixAndCollisions() {
    let f = URL(filePath: "/t")
    let taken: Set<String> = ["/t/photo-converted.png", "/t/photo-converted-2.png"]
    let url = OutputNamer.outputURL(for: URL(filePath: "/s/photo.jpg"), suffix: "converted", ext: "png", in: f, exists: { taken.contains($0.path) })
    #expect(url.lastPathComponent == "photo-converted-3.png")
}

@Test func emptySuffixUsesStemOnly() {
    let url = OutputNamer.outputURL(for: URL(filePath: "/s/photo.jpg"), suffix: "", ext: "png", in: URL(filePath: "/t"), exists: { _ in false })
    #expect(url.lastPathComponent == "photo.png")
}

@Test func tarGzStem() { #expect(OutputNamer.stem(of: URL(filePath: "/a/b.tar.gz")) == "b") }
@Test func onlyLastExtensionDropped() { #expect(OutputNamer.stem(of: URL(filePath: "/a/a.b.png")) == "a.b") }

@Test func numbered() {
    let names = OutputNamer.numberedURLs(for: URL(filePath: "/s/doc.pdf"), suffix: "page", ext: "png", count: 2, in: URL(filePath: "/t"), exists: { _ in false }).map(\.lastPathComponent)
    #expect(names == ["doc-page-1.png", "doc-page-2.png"])
}

@Test func numberedEachMadeUnique() {
    let taken: Set<String> = ["/t/doc-page-1.png"]
    let names = OutputNamer.numberedURLs(for: URL(filePath: "/s/doc.pdf"), suffix: "page", ext: "png", count: 2, in: URL(filePath: "/t"), exists: { taken.contains($0.path) }).map(\.lastPathComponent)
    #expect(names == ["doc-page-1-2.png", "doc-page-2.png"])
}

@Test func emptyExtIsFolder() {
    let u = OutputNamer.uniqueURL(in: URL(filePath: "/t"), base: "Archive", ext: "", exists: { _ in false })
    #expect(u.lastPathComponent == "Archive")
}

@Test func emptyExtCollisionHasNoDot() {
    let u = OutputNamer.uniqueURL(in: URL(filePath: "/t"), base: "Archive", ext: "", exists: { $0.lastPathComponent == "Archive" })
    #expect(u.lastPathComponent == "Archive-2")
}

@Test func readOnlyFallsBack() throws {
    let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
    let fb = tmp.appending(path: "fb")
    let r = OutputLocator.folder(for: URL(filePath: "/Volumes/X/a.png"), fallback: fb, isWritable: { _ in false })
    #expect(r.url == fb && r.usedFallback && FileManager.default.fileExists(atPath: fb.path))
}

@Test func writableUsesSourceFolder() throws {
    let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
    let fb = tmp.appending(path: "fb")
    let r = OutputLocator.folder(for: URL(filePath: "/Volumes/X/a.png"), fallback: fb, isWritable: { _ in true })
    #expect(r.url.path == "/Volumes/X" && !r.usedFallback && !FileManager.default.fileExists(atPath: fb.path))
}

@Test func natural() {
    let sorted = naturalSorted(["img10.png", "img2.png", "img1.png"].map { URL(filePath: "/x/\($0)") })
    #expect(sorted.map(\.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
}

@Test func undoTrashCallsTrash() throws {
    let a = URL(filePath: "/nonexistent/a.png")
    var trashed: [URL] = []
    try UndoPerformer.perform(.trash([a]), trash: { trashed.append($0) })
    #expect(trashed == [a])
}

@Test func undoMoveBackRestores() throws {
    let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
    let orig = tmp.appending(path: "a.txt")
    let dest = tmp.appending(path: "dest", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
    let moved = dest.appending(path: "a.txt")
    try Data("x".utf8).write(to: moved)
    try UndoPerformer.perform(.moveBack([FileMove(from: orig, to: moved)]))
    #expect(FileManager.default.fileExists(atPath: orig.path) && !FileManager.default.fileExists(atPath: moved.path))
}

@Test func undoMoveBackAvoidsTakenOriginal() throws {
    let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
    let orig = tmp.appending(path: "a.txt")
    let moved = tmp.appending(path: "dest/a.txt")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("new".utf8).write(to: orig)
    try Data("moved".utf8).write(to: moved)
    try UndoPerformer.perform(.moveBack([FileMove(from: orig, to: moved)]))
    #expect(try String(contentsOf: orig, encoding: .utf8) == "new")
    #expect(try String(contentsOf: tmp.appending(path: "a-2.txt"), encoding: .utf8) == "moved")
    #expect(!FileManager.default.fileExists(atPath: moved.path))
}

@Test func undoMoveBackKeepsTarGzExtension() throws {
    let tmp = try makeTempDir(); defer { try? FileManager.default.removeItem(at: tmp) }
    let orig = tmp.appending(path: "backup.tar.gz")
    let moved = tmp.appending(path: "dest/backup.tar.gz")
    try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("new".utf8).write(to: orig)
    try Data("moved".utf8).write(to: moved)
    try UndoPerformer.perform(.moveBack([FileMove(from: orig, to: moved)]))
    #expect(try String(contentsOf: tmp.appending(path: "backup-2.tar.gz"), encoding: .utf8) == "moved")
    #expect(!FileManager.default.fileExists(atPath: moved.path))
}
