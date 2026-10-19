import Foundation
import Testing
@testable import OrbitCore

@Suite final class OfficeAndSubtitleTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    static let srt = "1\n00:00:01,500 --> 00:00:03,000\n<i>Hello</i> there\n\n2\n00:00:04,000 --> 00:00:05,250\nBye\n"

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func run(_ url: URL, _ action: SliceAction, caps: Capabilities) async throws -> JobResult {
        let rootPath = root.path + "/"
        let runner = JobRunner(
            processors: ProcessorRegistry.standard(capabilities: caps), capabilities: caps, fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
        return try await runner.run(JobRequest(items: [DroppedItem(url: url)], action: action), progress: { _ in })
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    private func names(_ dir: URL) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() }

    // MARK: Subtitles

    @Test func srtToVtt() {
        #expect(SubtitleConverter.vtt(SubtitleConverter.parse(Self.srt, format: .srt))
                == "WEBVTT\n\n00:00:01.500 --> 00:00:03.000\n<i>Hello</i> there\n\n00:00:04.000 --> 00:00:05.250\nBye\n")
    }

    @Test func vttToSrtDropsNotes() {
        let vtt = "WEBVTT\n\nNOTE skip me\n\n00:00:01.500 --> 00:00:03.000 align:start\nHi\n"
        #expect(SubtitleConverter.srt(SubtitleConverter.parse(vtt, format: .vtt)) == "1\n00:00:01,500 --> 00:00:03,000\nHi\n")
    }

    @Test func plain() {
        #expect(SubtitleConverter.plainText(SubtitleConverter.parse(Self.srt, format: .srt)) == "Hello there\nBye\n")
    }

    @Test func vttDropsStyleRegionAndSettings() {
        let vtt = """
        WEBVTT - title

        STYLE
        ::cue { color: red }

        REGION
        id:fred

        NOTE
        multi line note
        --> not a cue

        intro
        00:01.000 --> 00:02.500 line:0 position:10%
        First
        line two

        01:00:03.000 --> 01:00:04.000
        Second

        """
        #expect(SubtitleConverter.parse(vtt, format: .vtt)
                == [Cue(start: 1, end: 2.5, text: "First\nline two"), Cue(start: 3603, end: 3604, text: "Second")])
    }

    @Test func srtParsingHandlesCRLFBOMAndBlankRuns() {
        let raw = "\u{FEFF}1\r\n00:00:00,100 --> 00:00:00,900\r\nA\r\n\r\n\r\n\r\n7\r\n00:00:01,000 --> 00:00:02,000\r\nB\r\nC\r\n"
        #expect(SubtitleConverter.parse(raw, format: .srt) == [Cue(start: 0.1, end: 0.9, text: "A"), Cue(start: 1, end: 2, text: "B\nC")])
        #expect(SubtitleConverter.parse("", format: .srt) == [])
        #expect(SubtitleConverter.parse("no cues here", format: .vtt) == [])
    }

    @Test func plainTextStripsTagsAndJoinsLines() {
        let cues = [Cue(start: 0, end: 1, text: "<b>Bold</b> {\\an8}text\nsecond <font color=\"red\">line</font>")]
        #expect(SubtitleConverter.plainText(cues) == "Bold text second line\n")
        #expect(SubtitleConverter.plainText([]) == "")
        #expect(SubtitleConverter.srt([]) == "")
        #expect(SubtitleConverter.vtt([]) == "WEBVTT\n\n")
    }

    @Test func timestampsRoundToTheMillisecond() {
        let cues = [Cue(start: 3661.2345, end: 359_999.9996, text: "x")]
        #expect(SubtitleConverter.srt(cues) == "1\n01:01:01,235 --> 100:00:00,000\nx\n")
    }

    @Test func absurdTimestampsAreRejectedNotTrapped() {
        let huge = "1\n00:00:99999999999999999999 --> 00:00:02,000\nBad\n\n2\n00:00:01,000 --> 00:00:02,000\nGood\n"
        #expect(SubtitleConverter.parse(huge, format: .srt) == [Cue(start: 1, end: 2, text: "Good")])
        let vtt = "WEBVTT\n\n00:01.000 --> 99999999999999999999:00:00.000\nBad\n\n00:03.000 --> 00:04.000\nGood\n"
        #expect(SubtitleConverter.parse(vtt, format: .vtt) == [Cue(start: 3, end: 4, text: "Good")])
        // Cues built by hand can be absurd too; formatting must clamp instead of crashing.
        let extremes = [Cue(start: .infinity, end: 1e300, text: "x"), Cue(start: .nan, end: -5, text: "y")]
        #expect(SubtitleConverter.srt(extremes).contains("99:59:59,999") == false)
        #expect(SubtitleConverter.srt(extremes).contains("00:00:00,000"))
    }

    @Test func textDecodingHandlesEveryByteOrderMark() {
        let text = "Grüße, Orbit"
        func bytes(_ bom: [UInt8], _ encoding: String.Encoding) -> Data { Data(bom) + text.data(using: encoding)! }
        #expect(TextDecoding.string(from: bytes([0xFF, 0xFE], .utf16LittleEndian)) == text)
        #expect(TextDecoding.string(from: bytes([0xFE, 0xFF], .utf16BigEndian)) == text)
        #expect(TextDecoding.string(from: bytes([0xFF, 0xFE, 0x00, 0x00], .utf32LittleEndian)) == text)
        #expect(TextDecoding.string(from: bytes([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian)) == text)
        #expect(TextDecoding.string(from: bytes([0xEF, 0xBB, 0xBF], .utf8)) == text)
        #expect(TextDecoding.string(from: Data([0x63, 0x61, 0x66, 0xE9])) == "café")   // Latin-1 / Windows-1252
        #expect(TextDecoding.string(from: Data([0x81, 0x8D])).count == 2)              // undefined in 1252: Latin-1 last resort
    }

    @Test func utf32SubtitleIsDecoded() async throws {
        let src = Fixtures.encodedText(Self.srt, "u32.srt", encoding: .utf32LittleEndian, bom: [0xFF, 0xFE, 0x00, 0x00], in: root)
        let o = try #require(try await run(src, .convert(.txt), caps: .none).outputs.first)
        #expect(try text(o) == "Hello there\nBye\n")
    }

    @Test(arguments: [OutputFormat.vtt, .txt])
    func srtFileConverts(f: OutputFormat) async throws {
        let src = Fixtures.text(Self.srt, "movie.srt", in: root)
        let o = try #require(try await run(src, .convert(f), caps: .none).outputs.first)
        #expect(o.lastPathComponent == "movie-converted.\(f.fileExtension)")
        #expect(try text(o) == (f == .vtt
            ? "WEBVTT\n\n00:00:01.500 --> 00:00:03.000\n<i>Hello</i> there\n\n00:00:04.000 --> 00:00:05.250\nBye\n"
            : "Hello there\nBye\n"))
    }

    @Test func vttFileToSrtWithWeirdName() async throws {
        let src = Fixtures.text("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nHé\n", "-rf 'q\" ü.vtt", in: root)
        let o = try #require(try await run(src, .convert(.srt), caps: .none).outputs.first)
        #expect(o.lastPathComponent == "-rf 'q\" ü-converted.srt")
        #expect(try text(o) == "1\n00:00:01,000 --> 00:00:02,000\nHé\n")
    }

    @Test func utf16SubtitleIsDecoded() async throws {
        let src = Fixtures.encodedText(Self.srt, "u16.srt", encoding: .utf16LittleEndian, bom: [0xFF, 0xFE], in: root)
        let o = try #require(try await run(src, .convert(.txt), caps: .none).outputs.first)
        #expect(try text(o) == "Hello there\nBye\n")
    }

    // MARK: Spreadsheets, pure Swift

    @Test func csvToTsv() async throws {
        let o = try await run(Fixtures.text("a,b\n1,2\n", "s.csv", in: root), .convert(.tsv), caps: .none).outputs[0]
        #expect(try text(o) == "a\tb\n1\t2\n")
    }

    @Test func tsvToCsvQuotesAndBOM() async throws {
        let src = Fixtures.encodedText("a\t\"b,c\"\n1\t2\n", "s.tsv", encoding: .utf8, bom: [0xEF, 0xBB, 0xBF], in: root)
        let o = try await run(src, .convert(.csv), caps: .none).outputs[0]
        #expect(try text(o) == "a,\"b,c\"\n1,2\n")
    }

    @Test func csvToODSRoundTrip() async throws {
        #expect(try await ODSReader.read(run(Fixtures.text("a,b\n1,2\n", "s.csv", in: root), .convert(.ods), caps: .none).outputs[0]) == [["a", "b"], ["1", "2"]])
    }

    @Test func csvToXLSXPure() async throws {
        let o = try await run(Fixtures.text("a,b\n1,2\n", "s.csv", in: root), .convert(.xlsx), caps: .none).outputs[0]
        #expect(try await Fixtures.unzipRead(o, "xl/worksheets/sheet1.xml").contains("<v>2</v>"))
    }

    @Test func odsToCsvAndXlsx() async throws {
        let ods = try await Fixtures.odsFile([["name", "id"], ["x", "007"]], in: root)
        let csv = try await run(ods, .convert(.csv), caps: .none).outputs[0]
        #expect(try text(csv) == "name,id\nx,007\n")
        let x = try await run(ods, .convert(.xlsx), caps: .none).outputs[0]
        let sheet = try await Fixtures.unzipRead(x, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("007") && !sheet.contains("<v>7</v>"))
    }

    @Test func csvToODSKeepsInteriorEmptyCells() async throws {
        let o = try await run(Fixtures.text("a,,c\n,,\nd,e,f\n", "gaps.csv", in: root), .convert(.ods), caps: .none).outputs[0]
        let rows = try await ODSReader.read(o)
        #expect(rows[0] == ["a", "", "c"] && rows.last == ["d", "e", "f"])
    }

    // MARK: Helper requirements

    @Test func numbersIsRequiredToReadXLSXAndForPDFAndNumbers() async throws {
        let xlsx = try await Fixtures.xlsxFile([["a", "b"]], in: root)
        let csv = Fixtures.text("a,b\n", "p.csv", in: root)
        let before = try names(root)
        await #expect(throws: OrbitError.helperMissing(.numbers)) { _ = try await self.run(xlsx, .convert(.csv), caps: .none) }
        await #expect(throws: OrbitError.helperMissing(.numbers)) { _ = try await self.run(csv, .convert(.pdf), caps: .none) }
        await #expect(throws: OrbitError.helperMissing(.numbers)) { _ = try await self.run(csv, .convert(.numbers), caps: .none) }
        #expect(try names(root) == before)
        #expect(try names(fallback).isEmpty)
    }

    @Test func keynoteIsRequiredForSlides() async throws {
        let deck = try await Fixtures.pptxDeck(slides: 2, in: root)
        let before = try names(root)
        for f in [OutputFormat.pdf, .png, .jpg, .key] {
            await #expect(throws: OrbitError.helperMissing(.keynote)) { _ = try await self.run(deck, .convert(f), caps: .none) }
        }
        #expect(try names(root) == before)
    }

    // MARK: iWork-driven pieces that can be checked without the apps

    @Test func firstCSVPicksTheFirstSheetInNaturalOrder() throws {
        let dir = root.appending(path: "export", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        _ = Fixtures.file("book-Sheet 10.csv", "ten\n", in: dir)
        _ = Fixtures.file("book-Sheet 2.csv", "two\n", in: dir)
        _ = Fixtures.file("notes.txt", "no\n", in: dir)
        _ = Fixtures.file(".hidden.csv", "no\n", in: dir)
        #expect(SpreadsheetProcessor.firstCSV(in: dir)?.lastPathComponent == "book-Sheet 2.csv")
        let single = Fixtures.file("single.csv", "a\n", in: root)
        #expect(SpreadsheetProcessor.firstCSV(in: single) == single)
        let empty = root.appending(path: "empty", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: false)
        #expect(SpreadsheetProcessor.firstCSV(in: empty) == nil)
        #expect(SpreadsheetProcessor.firstCSV(in: root.appending(path: "missing")) == nil)
    }

    @Test func slideImagesAreFoundInNaturalOrder() throws {
        let dir = root.appending(path: "slides", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        for n in ["deck.10.png", "deck.2.png", "deck.1.png", "readme.txt", ".DS_Store"] { _ = Fixtures.file(n, "x", in: dir) }
        #expect(SlidesProcessor.images(in: dir).map(\.lastPathComponent) == ["deck.1.png", "deck.2.png", "deck.10.png"])
        let jpgs = root.appending(path: "jpgs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: jpgs, withIntermediateDirectories: false)
        for n in ["a.jpeg", "b.JPG"] { _ = Fixtures.file(n, "x", in: jpgs) }
        #expect(SlidesProcessor.images(in: jpgs).map(\.lastPathComponent) == ["a.jpeg", "b.JPG"])
    }

    @Test func scriptsForTheFormatsThisTaskUses() {
        let slides = IWorkBridge.script(app: .keynote, bundleID: "com.apple.Keynote", format: .slideImages(.png))
        #expect(slides.contains("as slide images") && slides.contains("PNG"))
        #expect(IWorkBridge.script(app: .numbers, bundleID: "com.apple.Numbers", format: .csv).contains("as CSV"))
        #expect(IWorkBridge.script(app: .numbers, bundleID: "com.apple.Numbers", format: .excel).contains("as Microsoft Excel"))
    }

    // MARK: Real Keynote and Numbers

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_IWORK_TESTS"] == "1"))
    func keynoteAndNumbers() async throws {
        // Keynote: a two-slide deck becomes numbered PNGs, in order, beside the source.
        let deck = try await Fixtures.pptxDeck(slides: 2, in: root)
        let images = try await run(deck, .convert(.png), caps: Fixtures.caps).outputs
        #expect(images.map(\.lastPathComponent) == ["a-slide-1.png", "a-slide-2.png"])
        #expect(images.allSatisfy { Fixtures.size($0).width > 0 })
        let pdf = try await run(deck, .convert(.pdf), caps: Fixtures.caps).outputs[0]
        #expect(pdf.pathExtension == "pdf")
        // Numbers: an xlsx written by Orbit reads back as CSV, and a CSV becomes a Numbers document.
        let sheet = try await Fixtures.xlsxFile([["a", "b"], ["1", "2"]], in: root)
        let csv = try await run(sheet, .convert(.csv), caps: Fixtures.caps).outputs[0]
        #expect(try text(csv).contains("a,b"))
        let numbers = try await run(Fixtures.text("a,b\n1,2\n", "n.csv", in: root), .convert(.numbers), caps: Fixtures.caps).outputs[0]
        #expect(numbers.pathExtension == "numbers")
    }
}
