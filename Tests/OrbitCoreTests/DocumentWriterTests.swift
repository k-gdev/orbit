import AppKit
import Foundation
import Testing
@testable import OrbitCore

@Suite final class DocumentWriterTests {
    let tmp = Fixtures.tempDir()
    deinit { try? FileManager.default.removeItem(at: tmp) }

    @Test func csvQuoting() {
        let rows = DelimitedText.parse("a,\"b,c\",\"d \"\"q\"\"\"\n1,2,3\n", delimiter: ",")
        #expect(rows == [["a", "b,c", "d \"q\""], ["1", "2", "3"]])
        #expect(DelimitedText.parse(DelimitedText.write(rows, delimiter: "\t"), delimiter: "\t") == rows)
    }

    @Test func csvEdgeCases() {
        #expect(DelimitedText.parse("a,b\r\nc,d", delimiter: ",") == [["a", "b"], ["c", "d"]])
        #expect(DelimitedText.parse("\"x\ny\",z\n", delimiter: ",") == [["x\ny", "z"]])
        #expect(DelimitedText.parse("", delimiter: ",") == [])
        #expect(DelimitedText.write([["a,b", "c\"d", "e\nf", "g"]], delimiter: ",") == "\"a,b\",\"c\"\"d\",\"e\nf\",g\n")
        #expect(DelimitedText.write([["a\tb", "c"]], delimiter: "\t") == "\"a\tb\"\tc\n")
        #expect(DelimitedText.parse("a,,\n", delimiter: ",") == [["a", "", ""]])
    }

    @Test func xlsx() async throws {
        let o = tmp.appending(path: "t.xlsx")
        try await XLSXWriter.write(rows: [["Name", "Qty"], ["Apple", "3"]], sheetName: "Sheet1", to: o)
        let list = try await Fixtures.unzipList(o)
        #expect(list.contains("xl/worksheets/sheet1.xml") && list.contains("[Content_Types].xml"))
        for part in ["_rels/.rels", "xl/workbook.xml", "xl/_rels/workbook.xml.rels"] { #expect(list.contains(part)) }
        let sheet = try await Fixtures.unzipRead(o, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("<v>3</v>") && sheet.contains("Apple"))
        #expect(sheet.contains("t=\"inlineStr\""))
    }

    @Test func xlsxEscapesAndTextNumbers() async throws {
        let o = tmp.appending(path: "e.xlsx")
        try await XLSXWriter.write(rows: [["a<b & \"c\" > d", "007", "nan", "0x10"], ["", "1.5"]], sheetName: "A&B", to: o)
        let sheet = try await Fixtures.unzipRead(o, "xl/worksheets/sheet1.xml")
        #expect(sheet.contains("a&lt;b &amp; &quot;c&quot; &gt; d"))
        #expect(!sheet.contains("<v>7</v>") && !sheet.contains("<v>16</v>") && !sheet.contains("<v>nan"))
        #expect(sheet.contains("<c r=\"B2\"><v>1.5</v></c>"))
        let wb = try await Fixtures.unzipRead(o, "xl/workbook.xml")
        #expect(wb.contains("A&amp;B"))
        for xml in [sheet, wb] { #expect(XMLDocumentCheck.isWellFormed(xml)) }
    }

    @Test func xlsxRefusesToOverwrite() async throws {
        let o = tmp.appending(path: "x.xlsx")
        try Data("mine".utf8).write(to: o)
        await #expect(throws: (any Error).self) { try await XLSXWriter.write(rows: [["a"]], sheetName: "S", to: o) }
        #expect(try String(contentsOf: o, encoding: .utf8) == "mine")
    }

    @Test func odsRoundTrip() async throws {
        let o = tmp.appending(path: "t.ods")
        let rows = [["a", "1"], ["b", "2.5"]]
        try await ODSWriter.write(rows: rows, sheetName: "S", to: o)
        #expect(try await ODSReader.read(o) == rows)
        #expect(try await Fixtures.unzipList(o).first == "mimetype")
        #expect(try await Fixtures.zipMethod(o, "mimetype") == "Stored")
        #expect(try await Fixtures.unzipRead(o, "mimetype") == "application/vnd.oasis.opendocument.spreadsheet")
    }

    @Test func odsRoundTripSpecialText() async throws {
        let o = tmp.appending(path: "s.ods")
        let rows = [["<&>\"", "two  spaces", "line1\nline2"], ["", "x"]]
        try await ODSWriter.write(rows: rows, sheetName: "S<1>", to: o)
        #expect(try await ODSReader.read(o) == rows)
    }

    @Test func odsReaderHonorsRepeats() async throws {
        let dir = tmp.appending(path: "ods-src", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">\
        <office:body><office:spreadsheet><table:table table:name="One">
        <table:table-row><table:table-cell office:value-type="string"><text:p>a</text:p></table:table-cell>\
        <table:table-cell table:number-columns-repeated="2" office:value-type="string"><text:p>r</text:p></table:table-cell>\
        <table:table-cell table:number-columns-repeated="1000000"/></table:table-row>
        <table:table-row table:number-rows-repeated="2"><table:table-cell office:value-type="float" office:value="7"><text:p>7</text:p></table:table-cell></table:table-row>
        <table:table-row table:number-rows-repeated="1048576"><table:table-cell table:number-columns-repeated="1024"/></table:table-row>
        </table:table>
        <table:table table:name="Two"><table:table-row><table:table-cell><text:p>nope</text:p></table:table-cell></table:table-row></table:table>
        </office:spreadsheet></office:body></office:document-content>
        """
        try Data(content.utf8).write(to: dir.appending(path: "content.xml"))
        try Data("application/vnd.oasis.opendocument.spreadsheet".utf8).write(to: dir.appending(path: "mimetype"))
        let o = tmp.appending(path: "r.ods")
        try await ZipPackager.zip(directory: dir, to: o, storedFirst: "mimetype")
        #expect(try await ODSReader.read(o) == [["a", "r", "r"], ["7"], ["7"]])
    }

    private func png(_ name: String) -> URL { Fixtures.image(name, w: 16, h: 9, in: tmp) }

    @Test func pptx() async throws {
        let o = tmp.appending(path: "t.pptx")
        try await PPTXWriter.write(slideImages: [png("a.png"), png("b.png")], slideSize: .init(width: 960, height: 540), to: o)
        let l = try await Fixtures.unzipList(o)
        #expect(["ppt/slides/slide1.xml", "ppt/slides/slide2.xml", "ppt/media/image1.png", "ppt/media/image2.png",
                 "[Content_Types].xml", "ppt/presentation.xml", "ppt/slideMasters/slideMaster1.xml",
                 "ppt/slideLayouts/slideLayout1.xml", "ppt/theme/theme1.xml"].allSatisfy(l.contains))
        let slide = try await Fixtures.unzipRead(o, "ppt/slides/slide1.xml")
        #expect(slide.contains("cx=\"12192000\"") && slide.contains("cy=\"6858000\""))
        let pres = try await Fixtures.unzipRead(o, "ppt/presentation.xml")
        #expect(pres.contains("<p:sldSz cx=\"12192000\" cy=\"6858000\"/>"))
        for part in l where part.hasSuffix(".xml") || part.hasSuffix(".rels") {
            #expect(XMLDocumentCheck.isWellFormed(try await Fixtures.unzipRead(o, part)), "\(part)")
        }
    }

    @Test func pptxRejectsEmptyAndUnknownImages() async throws {
        let size = CGSize(width: 10, height: 10)
        let empty = tmp.appending(path: "n.pptx")
        await #expect(throws: (any Error).self) { try await PPTXWriter.write(slideImages: [], slideSize: size, to: empty) }
        let weird = Fixtures.file("x.heic", "nope", in: tmp)
        let bad = tmp.appending(path: "n2.pptx")
        await #expect(throws: (any Error).self) { try await PPTXWriter.write(slideImages: [weird], slideSize: size, to: bad) }
        #expect(!FileManager.default.fileExists(atPath: bad.path))
    }

    @Test func epub() async throws {
        let o = tmp.appending(path: "t.epub")
        try await EPUBWriter.write(title: "T", author: nil, chapters: [.init(title: "One", xhtmlBody: "<p>Hello Orbit</p>")], to: o)
        #expect(try await Fixtures.unzipList(o).first == "mimetype")
        #expect(try await Fixtures.unzipRead(o, "mimetype") == "application/epub+zip")
        #expect(try await Fixtures.zipMethod(o, "mimetype") == "Stored")
        #expect(try await Fixtures.unzipRead(o, "OEBPS/chapter-1.xhtml").contains("Hello Orbit"))
        let list = try await Fixtures.unzipList(o)
        for part in ["META-INF/container.xml", "OEBPS/content.opf", "OEBPS/nav.xhtml"] { #expect(list.contains(part)) }
        for part in list where part != "mimetype" {
            #expect(XMLDocumentCheck.isWellFormed(try await Fixtures.unzipRead(o, part)), "\(part)")
        }
    }

    @Test func epubMetadataAndEscaping() async throws {
        let o = tmp.appending(path: "m.epub")
        try await EPUBWriter.write(title: "A & B <1>", author: "Ann \"Q\"", chapters: [
            .init(title: "One & Two", xhtmlBody: "<p>x</p>"), .init(title: "Three", xhtmlBody: "<p>y</p>")], to: o)
        let opf = try await Fixtures.unzipRead(o, "OEBPS/content.opf")
        #expect(opf.contains("A &amp; B &lt;1&gt;") && opf.contains("Ann &quot;Q&quot;") && opf.contains("chapter-2.xhtml"))
        let nav = try await Fixtures.unzipRead(o, "OEBPS/nav.xhtml")
        #expect(nav.contains("One &amp; Two") && nav.contains("chapter-1.xhtml") && nav.contains("chapter-2.xhtml"))
    }

    @Test func markdown() {
        let sample = NSMutableAttributedString()
        sample.append(NSAttributedString(string: "Title\n", attributes: [.font: NSFont.systemFont(ofSize: 24)]))
        sample.append(NSAttributedString(string: "Hi", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        sample.append(NSAttributedString(string: " ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        sample.append(NSAttributedString(string: "link", attributes: [.font: NSFont.systemFont(ofSize: 12), .link: URL(string: "https://x.y")!]))
        #expect(MarkdownWriter.markdown(from: sample) == "# Title\n\n**Hi** [link](https://x.y)\n")
    }

    @Test func markdownHeadingsItalicAndLists() {
        let body = NSFont.systemFont(ofSize: 12)
        let italic = NSFontManager.shared.convert(body, toHaveTrait: .italicFontMask)
        let listStyle = NSMutableParagraphStyle()
        listStyle.textLists = [NSTextList(markerFormat: .disc, options: 0)]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "Big\n", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
        s.append(NSAttributedString(string: "Mid\n", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        s.append(NSAttributedString(string: "plain text here and ", attributes: [.font: body]))
        s.append(NSAttributedString(string: "slanted", attributes: [.font: italic]))
        s.append(NSAttributedString(string: " end\n", attributes: [.font: body]))
        s.append(NSAttributedString(string: "one\n", attributes: [.font: body, .paragraphStyle: listStyle]))
        s.append(NSAttributedString(string: "two\n", attributes: [.font: body, .paragraphStyle: listStyle]))
        s.append(NSAttributedString(string: "a*b", attributes: [.font: body]))
        #expect(MarkdownWriter.markdown(from: s) == "# Big\n\n## Mid\n\nplain text here and *slanted* end\n\n- one\n- two\n\na\\*b\n")
    }

    @Test func markdownEmpty() {
        #expect(MarkdownWriter.markdown(from: NSAttributedString(string: "")) == "")
    }
}

/// Well-formedness check used to prove escaping is correct.
enum XMLDocumentCheck {
    static func isWellFormed(_ xml: String) -> Bool {
        XMLParser(data: Data(xml.utf8)).parse()
    }
}
