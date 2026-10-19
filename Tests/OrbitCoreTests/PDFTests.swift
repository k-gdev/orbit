import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import OrbitCore

@Suite final class PDFTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    let doc: URL

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
        doc = Fixtures.pdf("doc.pdf", pages: ["Page one secret SSN 123-45-6789", "Page two public"],
                           embeddedImagePixels: 3000, author: "Kevo Secret Author", in: root)
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

    private func pdf(_ name: String, pages: [String], letter: Bool = true) -> URL {
        Fixtures.pdf(name, pages: pages, letter: letter, in: root)
    }

    private func runMany(_ urls: [URL], _ action: SliceAction, _ parameters: ToolParameters = .none) async throws -> JobResult {
        try await runner().run(JobRequest(items: urls.map(DroppedItem.init(url:)), action: action, parameters: parameters),
                               progress: { _ in })
    }

    private func run(_ url: URL, _ action: SliceAction) async throws -> JobResult { try await runMany([url], action) }

    private func runP(_ url: URL, _ action: SliceAction, _ parameters: ToolParameters) async throws -> JobResult {
        try await runMany([url], action, parameters)
    }

    private func size(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    /// The bounds of the secret on page 0, in page space.
    private func secretRect(_ url: URL) throws -> CGRect {
        let document = try #require(PDFDocument(url: url))
        let selection = try #require(document.findString("123-45-6789", withOptions: []).first)
        return selection.bounds(for: try #require(document.page(at: 0)))
    }

    // MARK: Convert

    @Test func toPNG300() async throws {
        let r = try await run(doc, .convert(.png))
        #expect(r.outputs.map(\.lastPathComponent) == ["doc-page-1.png", "doc-page-2.png"])
        #expect(Fixtures.size(r.outputs[0]) == CGSize(width: 2550, height: 3300))
    }

    @Test func toJPGAtOtherDPIOnWhite() async throws {
        let a4 = pdf("a4.pdf", pages: ["x"], letter: false)
        let r = try await runner().run(
            JobRequest(items: [DroppedItem(url: a4)], action: .convert(.jpg), options: JobOptions(pdfDPI: 144)),
            progress: { _ in })
        #expect(r.outputs.map(\.lastPathComponent) == ["a4-page-1.jpg"])
        #expect(Fixtures.size(r.outputs[0]) == CGSize(width: 1190, height: 1684))
        let corner = Fixtures.pixel(r.outputs[0], x: 1180, y: 1670)
        #expect(corner.r > 0.97 && corner.g > 0.97 && corner.b > 0.97)
    }

    @Test func pagesAreActuallyRendered() async throws {
        let r = try await run(doc, .convert(.png))
        // The embedded image sits at the top of page one: its centre is not white.
        let image = Fixtures.pixel(r.outputs[0], x: 300 * 172 / 72, y: 300 * 160 / 72)
        #expect(!image.isWhite)
        // Page two is only text near the top: the middle of the page stays white.
        #expect(Fixtures.pixel(r.outputs[1], x: 1275, y: 1650).isWhite)
    }

    @Test func toText() async throws {
        let text = try await String(contentsOf: run(doc, .convert(.txt)).outputs[0], encoding: .utf8)
        #expect(text.contains("Page two public"))
    }

    @Test func toMarkdown() async throws {
        let text = try await String(contentsOf: run(doc, .convert(.md)).outputs[0], encoding: .utf8)
        #expect(text.contains("---") && text.contains("Page one") && text.contains("Page two public"))
    }

    @Test(arguments: [OutputFormat.docx, .epub, .pptx, .xlsx])
    func toOffice(f: OutputFormat) async throws {
        let out = try await run(doc, .convert(f)).outputs[0]
        #expect(FileManager.default.fileExists(atPath: out.path))
        #expect(out.pathExtension == f.fileExtension)
        #expect(try size(out) > 0)
    }

    @Test func pptxSlides() async throws {
        let out = try await run(doc, .convert(.pptx)).outputs[0]
        let list = try await Fixtures.unzipList(out)
        #expect(list.contains("ppt/slides/slide2.xml") && !list.contains("ppt/slides/slide3.xml"))
        let presentation = try await Fixtures.unzipRead(out, "ppt/presentation.xml")
        // 612 x 792 points in EMU.
        #expect(presentation.contains("cx=\"7772400\" cy=\"10058400\""))
    }

    @Test func epubHasOneChapterPerPage() async throws {
        let out = try await run(doc, .convert(.epub)).outputs[0]
        let list = try await Fixtures.unzipList(out)
        #expect(list.contains("OEBPS/chapter-1.xhtml") && list.contains("OEBPS/chapter-2.xhtml"))
        #expect(try await Fixtures.unzipRead(out, "OEBPS/chapter-2.xhtml").contains("Page two public"))
    }

    @Test func xlsxSplitsColumnsOnWideGaps() async throws {
        let table = pdf("table.pdf", pages: ["Name\tQty\tPrice", "Apple\t3\t1.50 each"])
        let out = try await run(table, .convert(.xlsx)).outputs[0]
        let sheet = try await Fixtures.unzipRead(out, "xl/worksheets/sheet1.xml")
        for ref in ["A1", "B1", "C1", "A2", "B2", "C2"] { #expect(sheet.contains("r=\"\(ref)\""), "missing \(ref)") }
        #expect(sheet.contains("<c r=\"B2\"><v>3</v></c>"))
        // A normal word space stays inside its cell.
        #expect(sheet.contains("1.50 each"))
    }

    @Test func rotatedPageRendersRotated() async throws {
        let turned = try await runP(doc, .tool(.organize, nil), .pdfPages([PageOp(sourceIndex: 0, quarterTurns: 1)])).outputs[0]
        let r = try await run(turned, .convert(.png))
        #expect(Fixtures.size(r.outputs[0]) == CGSize(width: 3300, height: 2550))
        // Redaction on a rotated page still lands on the text: it is gone and the page keeps its shape.
        let rect = try secretRect(turned)
        let o = try await runP(turned, .tool(.redact, nil), .pdfRedactions([PDFRedaction(pageIndex: 0, rects: [rect])])).outputs[0]
        #expect(Fixtures.bytes(o).range(of: Data("123-45-6789".utf8)) == nil)
        #expect(PDFDocument(url: o)!.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612))

        // Render the redacted output and check the pixels. The page is turned a quarter clockwise, so a
        // page-space point (x, y) on the 612 x 792 sheet lands at pixel (y, x) with the origin top left.
        let turnedPage = try #require(PDFDocument(url: turned)?.page(at: 0))
        try #require(turnedPage.rotation == 90)
        let png = root.appending(path: "rotated-check.png")
        try PDFConverter.images(o, format: .png, dpi: 72, quality: 0.9, to: [png])
        #expect(Fixtures.size(png) == CGSize(width: 792, height: 612))
        let inside = Fixtures.pixel(png, x: Int(rect.midY), y: Int(rect.midX))
        #expect(inside.r < 0.05 && inside.g < 0.05 && inside.b < 0.05)
        // Just outside the rectangle, above and below the line of text, the page is still white.
        let above = Fixtures.pixel(png, x: Int(rect.maxY) + 4, y: Int(rect.midX))
        let below = Fixtures.pixel(png, x: Int(rect.minY) - 4, y: Int(rect.midX))
        #expect(above.isWhite && below.isWhite)
        // The unrotated mapping would land somewhere else entirely.
        #expect(Fixtures.pixel(png, x: Int(rect.midX), y: Int(792 - rect.midY)).isWhite)
    }

    @Test func docxKeepsText() async throws {
        let out = try await run(doc, .convert(.docx)).outputs[0]
        let text = try NSAttributedString(url: out, options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                                          documentAttributes: nil)
        #expect(text.string.contains("Page two public") && text.string.contains("Page one"))
    }

    @Test func textOutputsNeedRealText() async throws {
        let scanned = try await run(doc, .convert(.png)).outputs[0]
        let scannedPDF = root.appending(path: "scan.pdf")
        try await runner().run(JobRequest(items: [DroppedItem(url: scanned)], action: .convert(.pdf)), progress: { _ in })
            .outputs[0].moveSafely(to: scannedPDF)
        await #expect(throws: OrbitError.self) { try await self.run(scannedPDF, .convert(.txt)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("scan-converted") && $0.hasSuffix(".txt") }.isEmpty)
    }

    // MARK: Compress

    @Test func compressMediumKeepsText() async throws {
        let r = try await run(doc, .tool(.compress, .compress(.tier(.medium))))
        #expect(try size(r.outputs[0]) < size(doc))
        #expect(PDFDocument(url: r.outputs[0])!.string!.contains("Page two"))
        #expect(r.outputs[0].lastPathComponent == "doc-compressed.pdf")
    }

    @Test func compressStrongRasterizes() async throws {
        let r = try await run(doc, .tool(.compress, .compress(.tier(.strong))))
        let out = PDFDocument(url: r.outputs[0])!
        #expect(out.pageCount == 2)
        #expect(try size(r.outputs[0]) < size(doc) / 2)
    }

    @Test func compressFitUnderWins() async throws {
        let target = Int64(try size(doc) / 3)
        let r = try await run(doc, .tool(.compress, .compress(.fitUnder(target))))
        #expect(Int64(try size(r.outputs[0])) <= target)
    }

    @Test func compressFitUnderImpossible() async throws {
        await #expect(throws: OrbitError.targetTooSmall("Can't get this PDF under 100 bytes.")) {
            try await self.run(self.doc, .tool(.compress, .compress(.fitUnder(100))))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("compressed") }.isEmpty)
    }

    @Test func compressFromParameters() async throws {
        let r = try await runP(doc, .tool(.compress, nil), .compress(.tier(.light)))
        #expect(PDFDocument(url: r.outputs[0])!.pageCount == 2)
    }

    // MARK: Merge, split, organize

    @Test func merge() async throws {
        let r = try await runMany([pdf("doc10.pdf", pages: ["x", "y", "z"]), pdf("doc2.pdf", pages: ["a", "b"])], .tool(.merge, nil))
        let m = PDFDocument(url: r.outputs[0])!
        #expect(m.pageCount == 5 && m.page(at: 0)!.string!.contains("a"))
        #expect(r.outputs[0].lastPathComponent == "doc2-merged.pdf")
        #expect(r.outputs.count == 1)
    }

    @Test func splitEveryPage() async throws {
        let r = try await run(pdf("d.pdf", pages: ["1", "2", "3"]), .tool(.split, .pdfSplitEveryPage))
        #expect(r.outputs.map(\.lastPathComponent) == ["d-part-1.pdf", "d-part-2.pdf", "d-part-3.pdf"])
        #expect(r.outputs.map { PDFDocument(url: $0)!.pageCount } == [1, 1, 1])
    }

    @Test func splitRanges() async throws {
        let r = try await runP(pdf("d.pdf", pages: ["1", "2", "3"]), .tool(.split, nil), .pdfRanges([1...2, 3...3]))
        #expect(r.outputs.map { PDFDocument(url: $0)!.pageCount } == [2, 1])
        #expect(PDFDocument(url: r.outputs[1])!.page(at: 0)!.string!.contains("3"))
    }

    @Test func splitRangeOutsideTheDocumentFails() async throws {
        let d = pdf("d.pdf", pages: ["1", "2", "3"])
        await #expect(throws: OrbitError.self) { try await self.runP(d, .tool(.split, nil), .pdfRanges([2...5])) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("-part-") }.isEmpty)
    }

    @Test func organize() async throws {
        let o = PDFDocument(url: try await runP(doc, .tool(.organize, nil),
                                                 .pdfPages([PageOp(sourceIndex: 1, quarterTurns: 0), PageOp(sourceIndex: 0, quarterTurns: 1)])).outputs[0])!
        #expect(o.pageCount == 2)
        #expect(o.page(at: 0)!.string!.contains("Page two"))
        #expect(o.page(at: 1)!.rotation == 90)
    }

    @Test func organizeDeletesAndDuplicates() async throws {
        let d = pdf("d.pdf", pages: ["1", "2", "3"])
        let r = try await runP(d, .tool(.organize, nil), .pdfPages([PageOp(sourceIndex: 2), PageOp(sourceIndex: 2, quarterTurns: -1)]))
        let o = PDFDocument(url: r.outputs[0])!
        #expect(o.pageCount == 2 && o.page(at: 1)!.string!.contains("3") && o.page(at: 1)!.rotation == 270)
        #expect(r.outputs[0].lastPathComponent == "d-organized.pdf")
    }

    // MARK: Redact and metadata

    @Test func redactRemovesText() async throws {
        let rect = try secretRect(doc)
        let o = try await runP(doc, .tool(.redact, nil), .pdfRedactions([PDFRedaction(pageIndex: 0, rects: [rect])])).outputs[0]
        let d = PDFDocument(url: o)!
        #expect(!(d.page(at: 0)!.string ?? "").contains("123-45-6789"))
        #expect(Fixtures.bytes(o).range(of: Data("123-45-6789".utf8)) == nil)
        #expect(d.page(at: 1)!.string!.contains("Page two public"))
    }

    @Test func redactBlacksOutTheRectAndRasterizesTheWholePage() async throws {
        let rect = try secretRect(doc)
        let o = try await runP(doc, .tool(.redact, nil), .pdfRedactions([PDFRedaction(pageIndex: 0, rects: [rect])])).outputs[0]
        let d = PDFDocument(url: o)!
        #expect(d.pageCount == 2)
        // The rest of page one is text-free too: it is an image-only page now.
        #expect(!(d.page(at: 0)!.string ?? "").contains("Page one"))
        #expect(d.page(at: 0)!.bounds(for: .mediaBox).size == CGSize(width: 612, height: 792))
        // Render the output page: the middle of the redacted rect is black.
        let png = root.appending(path: "check.png")
        try PDFConverter.images(o, format: .png, dpi: 72, quality: 0.9, to: [png, root.appending(path: "check2.png")])
        let probe = Fixtures.pixel(png, x: Int(rect.midX), y: Int(792 - rect.midY))
        #expect(probe.r < 0.05 && probe.g < 0.05 && probe.b < 0.05)
    }

    @Test func redactRejectsEmptyRequests() async throws {
        await #expect(throws: OrbitError.self) { try await self.runP(self.doc, .tool(.redact, nil), .pdfRedactions([])) }
        await #expect(throws: OrbitError.self) {
            try await self.runP(self.doc, .tool(.redact, nil), .pdfRedactions([PDFRedaction(pageIndex: 9, rects: [CGRect(x: 0, y: 0, width: 5, height: 5)])]))
        }
    }

    @Test func stripMeta() async throws {
        // The fixture really carries the author, in Info and in XMP.
        #expect(Fixtures.bytes(doc).range(of: Data("Kevo Secret Author".utf8)) != nil)
        let o = try await run(doc, .tool(.metadata, .metadataStripAll)).outputs[0]
        #expect(PDFDocument(url: o)!.documentAttributes?[PDFDocumentAttribute.authorAttribute] == nil)
        #expect(Fixtures.bytes(o).range(of: Data("Kevo Secret Author".utf8)) == nil)
        #expect(PDFDocument(url: o)!.pageCount == 2 && PDFDocument(url: o)!.page(at: 1)!.string!.contains("Page two public"))
        #expect(o.lastPathComponent == "doc-clean.pdf")
    }

    @Test func sourceIsNeverTouched() async throws {
        let before = Fixtures.bytes(doc)
        _ = try await run(doc, .tool(.metadata, .metadataStripAll))
        _ = try await runP(doc, .tool(.redact, nil), .pdfRedactions([PDFRedaction(pageIndex: 0, rects: [try secretRect(doc)])]))
        _ = try await run(doc, .tool(.compress, .compress(.tier(.strong))))
        #expect(Fixtures.bytes(doc) == before)
    }

    // MARK: PAGES

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_IWORK_TESTS"] == "1"))
    func toPages() async throws {
        let out = try await run(doc, .convert(.pages)).outputs[0]
        #expect(FileManager.default.fileExists(atPath: out.path))
    }
}

private extension URL {
    /// Moves a produced file (inside the test's temp folder) to a new name.
    func moveSafely(to destination: URL) throws {
        try FileManager.default.moveItem(at: self, to: destination)
    }
}
