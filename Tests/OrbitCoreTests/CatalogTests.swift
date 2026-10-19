import Foundation
import Testing
@testable import OrbitCore

private let desktop = URL(fileURLWithPath: "/Users/test/Desktop", isDirectory: true)
private let downloads = URL(fileURLWithPath: "/Users/test/Downloads", isDirectory: true)
private let S = CatalogSettings(favouriteFolders: [desktop, downloads])

private func item(_ name: String) -> DroppedItem {
    DroppedItem(url: URL(fileURLWithPath: "/nonexistent/\(name)"))
}

private func content(_ wheel: WheelKind, _ names: [String], _ caps: Capabilities) -> WheelContent {
    SliceCatalog.content(for: names.map(item), wheel: wheel, capabilities: caps, settings: S)
}

private func titles(_ wheel: WheelKind, _ names: [String], _ caps: Capabilities) -> [String] {
    content(wheel, names, caps).slices.map(\.title)
}

private func slice(_ wheel: WheelKind, _ names: [String], _ title: String, _ caps: Capabilities = .everything) -> Slice {
    content(wheel, names, caps).slices.first { $0.title == title }!
}

private func childTitles(_ wheel: WheelKind, _ names: [String], _ title: String, _ caps: Capabilities = .everything) -> [String] {
    slice(wheel, names, title, caps).children.map(\.title)
}

private func fake(_ i: Int) -> Slice { Slice(id: "convert.f\(i)", title: "F\(i)") }

private func allIDs(_ c: WheelContent) -> [String] {
    func walk(_ s: Slice) -> [String] { [s.id] + s.children.flatMap(walk) }
    return c.slices.flatMap(walk)
}

@Test func pngConvertOmitsOwn()  { #expect(titles(.convert, ["a.png"], .everything) == ["JPG","HEIC","WEBP","TIFF","AVIF","BMP","GIF","ICO","PDF"]) }
@Test func movConvertNoFFmpeg()  { #expect(titles(.convert, ["a.mov"], .none) == ["MP4","GIF","M4A"]) }
@Test func movConvertAll()       { #expect(titles(.convert, ["a.mov"], .everything) == ["MP4","MKV","WEBM","AVI","WMV","GIF","M4A","MP3"]) }
@Test func mkvNeedsFFmpegHub()   { let c = content(.convert, ["a.mkv"], .none); #expect(c.slices.isEmpty && c.hubMessage == "Install ffmpeg to convert MKV") }
@Test func manyImagesOnePDF()    { #expect(slice(.convert, ["a.png","b.png"], "PDF").subtitle == "One PDF") }
@Test func mixedConvertArchives(){ #expect(titles(.convert, ["a.png","b.pdf"], .none) == ["ZIP","TAR","TAR.GZ"]) }
@Test func folderConvertArchives() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "orbit-cat-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let c = SliceCatalog.content(for: [DroppedItem(url: dir)], wheel: .convert, capabilities: .none, settings: S)
    #expect(c.slices.map(\.title) == ["ZIP","TAR","TAR.GZ"])
}
@Test func pngTools() {
    #expect(titles(.tools, ["a.png"], .none) == ["REMOVE BG","ADD BG","MARKUP","ADJUST","COMPRESS","METADATA","READ QR"])
    #expect(childTitles(.tools, ["a.png"], "COMPRESS", .none) == ["Light","Medium","Strong","Under 500 KB","Under 1 MB","Under 5 MB","Custom…"])
    #expect(slice(.tools, ["a.png"], "MARKUP", .none).editor == .imageMarkup)
}
@Test func manyJpgTools() {
    #expect(titles(.tools, ["a.jpg","b.jpg","c.jpg"], .none) == ["REMOVE BG","COMPRESS","METADATA","READ QR","COLLAGE"])
    #expect(childTitles(.tools, ["a.jpg","b.jpg"], "METADATA", .none) == ["Strip all","Strip location"])
}
@Test func mp4Tools() {
    #expect(titles(.tools, ["a.mp4"], .everything) == ["COMPRESS","TRIM","CROP","SPEED","SPLIT","SNAPSHOT","MUTE","REMOVE META"])
    #expect(childTitles(.tools, ["a.mp4"], "SPEED") == ["0.25×","0.5×","1.5×","2×","4×"])
}
@Test func twoMp4Tools() { #expect(titles(.tools, ["a.mp4","b.mp4"], .none) == ["COMPRESS","SPEED","MUTE","REMOVE META","JOIN"]) }
@Test func mp3ToolsNeedFFmpeg() {
    #expect(content(.tools, ["a.mp3"], .none).hubMessage == "Install ffmpeg to edit MP3")
    #expect(titles(.tools, ["a.mp3"], .everything) == ["COMPRESS","TRIM","NORMALIZE","BLEEP","CHANNELS","METADATA"])
}
@Test func wavCompressSaysM4A() { #expect(slice(.tools, ["a.wav"], "COMPRESS").subtitle == "Saves as M4A") }
@Test func pdfTools() {
    #expect(titles(.tools, ["a.pdf"], .none) == ["COMPRESS","SPLIT","ORGANIZE","REDACT","METADATA"])
    #expect(titles(.tools, ["a.pdf","b.pdf"], .none) == ["COMPRESS","MERGE","SPLIT","METADATA"])
}
@Test func mixedTools() {
    #expect(titles(.tools, ["a.png","b.pdf"], .none) == ["COMPRESS","REMOVE META"])
    #expect(content(.tools, ["a.png","b.docx"], .none).hubMessage == "No tool fits every file")
}
@Test func zipTools()  { #expect(titles(.tools, ["a.zip"], .none) == ["EXTRACT"]) }
@Test func docxNoTools() { #expect(content(.tools, ["a.docx"], .none).hubMessage == "No tools for DOCX files") }
@Test func actions() {
    #expect(titles(.actions, ["a.xyz"], .none) == ["FLOAT","AIRDROP","COPY PATH","TERMINAL","COPY TO","MOVE TO","ARCHIVE"])
    #expect(childTitles(.actions, ["a.xyz"], "COPY TO", .none) == ["Desktop","Downloads","Choose…"])
}
@Test func pptx() {
    #expect(content(.convert, ["a.pptx"], .none).hubMessage == "Install Keynote to convert PPTX")
    #expect(titles(.convert, ["a.pptx"], .everything) == ["PDF","JPG","PNG","KEY"])
}
@Test func pdfConvert() {
    #expect(titles(.convert, ["a.pdf"], .none) == ["JPG","PNG","TXT","MD","DOCX","EPUB","PPTX","XLSX"])
    #expect(titles(.convert, ["a.pdf"], .everything).contains("PAGES"))
}
@Test func csv() {
    #expect(titles(.convert, ["a.csv"], .none) == ["XLSX","TSV","ODS"])
    #expect(titles(.convert, ["a.csv"], .everything) == ["XLSX","TSV","PDF","NUMBERS","ODS"])
}
@Test func unknownType() { #expect(content(.convert, ["a.xyz"], .none).hubMessage == "Orbit can't convert this file type") }
@Test func srt() { #expect(titles(.convert, ["a.srt"], .none) == ["VTT","TXT"]) }
@Test func cappedAtTen() {
    let c = SliceCatalog.capped((0..<12).map(fake))
    #expect(c.count == 10 && c.last?.title == "MORE" && c.last?.children.count == 3)
}
@Test func idsUnique() {
    for w in WheelKind.allCases {
        let ids = allIDs(content(w, ["a.png"], .everything))
        #expect(Set(ids).count == ids.count)
    }
}

// Controller rulings R5/R6 and extras.
@Test func imageToolsNeverNeedFFmpeg() { #expect(!titles(.tools, ["a.webp"], .none).isEmpty) }
@Test func chooseFolderAppearsForMany() { #expect(childTitles(.actions, ["a.png","b.png"], "MOVE TO", .none).last == "Choose…") }
@Test func readHelperDoesNotGateToollessSelections() {
    #expect(content(.tools, ["a.pptx"], .none).hubMessage == "No tools for PPTX files")
    #expect(content(.tools, ["a.png","b.pages"], .none).hubMessage == "No tool fits every file")
    #expect(content(.tools, ["a.mkv"], .none).hubMessage == "Install ffmpeg to edit MKV")
}
@Test func multiFormatConvertOrderIsDropOrderIndependent() {
    let expected = ["JPG","PNG","HEIC","WEBP","TIFF","AVIF","BMP","GIF","ICO","PDF"]
    #expect(titles(.convert, ["a.png","b.jpg"], .everything) == expected)
    #expect(titles(.convert, ["b.jpg","a.png"], .everything) == expected)
    #expect(titles(.convert, ["a.mov","b.mp4"], .everything) == ["MP4","MOV","MKV","WEBM","AVI","WMV","GIF","M4A","MP3"])
    #expect(titles(.convert, ["b.mp4","a.mov"], .everything) == titles(.convert, ["a.mov","b.mp4"], .everything))
}
@Test func manyFavouriteFoldersAreCapped() {
    let folders = (0..<12).map { URL(fileURLWithPath: "/Users/test/F\($0)", isDirectory: true) }
    let c = SliceCatalog.content(for: [item("a.xyz")], wheel: .actions, capabilities: .none,
                                 settings: CatalogSettings(favouriteFolders: folders))
    for title in ["COPY TO", "MOVE TO"] {
        let kids = c.slices.first { $0.title == title }!.children
        #expect(kids.count <= 10 && kids.last?.title == "MORE")
    }
    let ids = allIDs(c)
    #expect(Set(ids).count == ids.count)
}
@Test func duplicatePresetsDoNotDuplicateIDs() {
    let st = CatalogSettings(favouriteFolders: [desktop, desktop],
                             imageFitPresets: [500_000, 500_000, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
                             videoFitPresets: [1_000_000, 1_000_000], pdfFitPresets: [1_000_000, 1_000_000])
    for name in ["a.png", "a.mp4", "a.pdf"] {
        let c = SliceCatalog.content(for: [item(name)], wheel: .tools, capabilities: .everything, settings: st)
        let ids = allIDs(c)
        #expect(Set(ids).count == ids.count)
        #expect(c.slices.first { $0.title == "COMPRESS" }!.children.count <= 10)
    }
}
@Test func idsUniqueAcrossFiles() {
    for names in [["a.mp4"], ["a.wav"], ["a.pdf"], ["a.pdf","b.pdf"], ["a.png","b.pdf"]] {
        let ids = allIDs(content(.tools, names, .everything))
        #expect(Set(ids).count == ids.count)
    }
    #expect(slice(.tools, ["a.png"], "COMPRESS").children.first { $0.title == "Under 500 KB" }?.id == "tools.compress.fit.500000")
    #expect(slice(.tools, ["a.mp4"], "SPEED").children.first { $0.title == "2×" }?.id == "tools.speed.2.0")
    #expect(slice(.actions, ["a.xyz"], "COPY TO").children.last?.id == "actions.copyTo.choose")
}
