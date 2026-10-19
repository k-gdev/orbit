import Foundation
import Testing
@testable import OrbitCore

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "orbit-class-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private let pngBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0, 0, 0, 0, 0])

@Test(arguments: [
    ("a.PNG", "png", FileCategory.image), ("a.jpeg", "jpg", .image), ("a.heif", "heic", .image), ("a.svg", "svg", .image),
    ("a.mkv", "mkv", .video), ("a.wmv", "wmv", .video), ("a.aif", "aiff", .audio), ("a.wma", "wma", .audio),
    ("a.pdf", "pdf", .pdf), ("a.markdown", "md", .document), ("a.textClipping", "textclipping", .document),
    ("a.key", "key", .slides), ("a.ods", "ods", .spreadsheet), ("a.vtt", "vtt", .subtitle),
    ("a.tar.gz", "tgz", .archive), ("a.rar", "rar", .archive), ("a.xyz", "xyz", .other),
])
func classifiesByExtension(name: String, key: String, cat: FileCategory) {
    let item = DroppedItem(url: URL(filePath: "/nonexistent/\(name)"))
    #expect(item.formatKey == key)
    #expect(item.category == cat)
}

@Test func pngNamedJpgIsPNG() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "photo.jpg")
    try pngBytes.write(to: url)
    let item = DroppedItem(url: url)
    #expect(item.formatKey == "png")
    #expect(item.category == .image)
}

@Test func extensionlessPNGIsImage() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "photo")
    try pngBytes.write(to: url)
    let item = DroppedItem(url: url)
    #expect(item.category == .image && item.formatKey == "png")
}

@Test func sniffsFtypBrands() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    for (brand, key) in [("heic", "heic"), ("avif", "avif"), ("qt  ", "mov"), ("isom", "mp4"), ("M4A ", "m4a")] {
        let url = dir.appending(path: "file-\(key)")
        var data = Data([0, 0, 0, 0x18]); data.append(Data("ftyp".utf8)); data.append(Data(brand.utf8)); data.append(Data(count: 4))
        try data.write(to: url)
        #expect(DroppedItem(url: url).formatKey == key)
    }
}

@Test func plainFolderIsFolder() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    #expect(DroppedItem(url: dir).category == .folder)
}

@Test func rtfdPackageIsDocument() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let pkg = dir.appending(path: "x.rtfd", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
    let item = DroppedItem(url: pkg)
    #expect(item.category == .document)
    #expect(item.formatKey == "rtfd")
}

@Test func appBundleIsOther() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let app = dir.appending(path: "X.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: app.appending(path: "Contents"), withIntermediateDirectories: true)
    #expect(DroppedItem(url: app).category == .other)
}

@Test func docxZipKeepsDocument() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "a.docx")
    try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]).write(to: url)
    let item = DroppedItem(url: url)
    #expect(item.category == .document)
    #expect(item.formatKey == "docx")
}

@Test func zipHeaderOnOtherExtensionIsZip() throws {
    let dir = try makeTempDir(); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appending(path: "a.dat")
    try Data([0x50, 0x4B, 0x03, 0x04, 0, 0, 0, 0]).write(to: url)
    let item = DroppedItem(url: url)
    #expect(item.category == .archive)
    #expect(item.formatKey == "zip")
}

@Test func outputFormatLabels() {
    #expect(OutputFormat.tgz.fileExtension == "tar.gz")
    #expect(OutputFormat.tgz.label == "TAR.GZ")
    #expect(OutputFormat.webp.label == "WEBP")
    #expect(OutputFormat.mp4.fileExtension == "mp4")
}

@Test func mkvNeedsFFmpeg() { #expect(MediaSupport.needsFFmpegToRead(DroppedItem(url: URL(filePath: "/x/a.mkv")))) }
@Test func movIsNative() { #expect(!MediaSupport.needsFFmpegToRead(DroppedItem(url: URL(filePath: "/x/a.mov")))) }
@Test func nativeWritability() {
    for k in ["mp4", "mov", "m4v", "m4a", "aac", "wav", "aiff", "flac"] { #expect(MediaSupport.isNativelyWritable(formatKey: k)) }
    for k in ["mkv", "mp3", "ogg", "png", "xyz"] { #expect(!MediaSupport.isNativelyWritable(formatKey: k)) }
}
