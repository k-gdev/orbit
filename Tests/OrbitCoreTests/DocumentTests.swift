import AppKit
import Foundation
import PDFKit
import Testing
@testable import OrbitCore

@Suite final class DocumentTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    static let weird = "-rf 'q\" ü.docx"

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

    private func textOf(_ url: URL) async throws -> String { try await Fixtures.textOf(url) }

    private func styled(_ title: String, _ body: String) -> NSAttributedString {
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: title + "\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)]))
        s.append(NSAttributedString(string: body, attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        return s
    }

    // MARK: Conversion

    @Test(arguments: [OutputFormat.pdf, .docx, .txt, .md, .html, .epub])
    func docxConverts(f: OutputFormat) async throws {
        // A docx converted to docx is skipped by the runner (R11), so that case starts from an rtf.
        let hello = NSAttributedString(string: "Hello Orbit", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let src = f == .docx ? Fixtures.richDocument(hello, type: .rtf, name: "doc.rtf", in: root) : Fixtures.docx("Hello Orbit", in: root)
        let o = try #require(try await run(src, .convert(f), caps: .none).outputs.first)
        #expect(o.lastPathComponent == "doc-converted.\(f.fileExtension)")
        #expect(try await textOf(o).contains("Hello Orbit"))
    }

    @Test func pdfPaperIsLetterForUS() {
        #expect(RichText.paperSize(for: Locale(identifier: "en_US")) == CGSize(width: 612, height: 792))
        #expect(RichText.paperSize(for: Locale(identifier: "en_GB")) == CGSize(width: 595, height: 842))
        for region in ["CA", "MX", "PH", "CL", "CO", "VE"] {
            #expect(RichText.paperSize(for: Locale(identifier: "es_\(region)")) == CGSize(width: 612, height: 792), "\(region)")
        }
        #expect(RichText.paperSize(for: Locale(identifier: "de_DE")) == CGSize(width: 595, height: 842))
        #expect(RichText.paperSize(for: Locale(identifier: "en")) == CGSize(width: 595, height: 842))
    }

    @Test func pdfPageMatchesLocalePaper() async throws {
        let o = try await run(Fixtures.docx("Hi", in: root), .convert(.pdf), caps: .none).outputs[0]
        let box = PDFDocument(url: o)!.page(at: 0)!.bounds(for: .mediaBox)
        #expect(box.size == RichText.paperSize(for: .current))
    }

    @Test func longTextPaginates() async throws {
        let src = Fixtures.text(String(repeating: "Para.\n\n", count: 400), "long.txt", in: root)
        let doc = PDFDocument(url: try await run(src, .convert(.pdf), caps: .none).outputs[0])!
        #expect(doc.pageCount > 1)
        #expect(doc.string!.contains("Para."))
    }

    @Test func pdfTextStaysWithinMargins() throws {
        let out = root.appending(path: "m.pdf")
        let text = NSAttributedString(string: String(repeating: "Wide words fill lines. ", count: 200),
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        try RichText.writePDF(text, to: out, paper: CGSize(width: 612, height: 792))
        let page = PDFDocument(url: out)!.page(at: 0)!
        let bounds = page.selection(for: page.bounds(for: .mediaBox))!.bounds(for: page)
        #expect(bounds.minX >= 71 && bounds.maxX <= 541 && bounds.minY >= 71 && bounds.maxY <= 721)
    }

    @Test func writePDFRefusesToOverwrite() throws {
        let out = Fixtures.file("e.pdf", "keep", in: root)
        #expect(throws: (any Error).self) {
            try RichText.writePDF(NSAttributedString(string: "x"), to: out, paper: CGSize(width: 612, height: 792))
        }
        #expect(try String(contentsOf: out, encoding: .utf8) == "keep")
    }

    @Test func markdownIn() async throws {
        let s = try await textOf(run(Fixtures.text("# Title\n\nSome **bold**", "a.md", in: root), .convert(.docx), caps: .none).outputs[0])
        #expect(s.contains("Title") && s.contains("bold"))
    }

    @Test func markdownStylesSurvive() async throws {
        let src = Fixtures.text("# Title\n\nSome **bold** and *ital*\n\n- one\n- two\n", "s.md", in: root)
        let attributed = try await RichText.read(DroppedItem(url: src), iwork: nil)
        func font(of word: String) -> NSFont? {
            let r = (attributed.string as NSString).range(of: word)
            return r.location == NSNotFound ? nil : attributed.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont
        }
        #expect(font(of: "Title")!.pointSize > font(of: "Some")!.pointSize)
        #expect(font(of: "bold")!.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(font(of: "ital")!.fontDescriptor.symbolicTraits.contains(.italic))
        #expect(attributed.string.contains("one") && attributed.string.contains("two"))
        #expect(!attributed.string.contains("**") && !attributed.string.contains("# "))
        #expect(attributed.string.contains("Title\n"))
    }

    @Test func richRoundTripKeepsHeadingInMarkdown() async throws {
        let src = Fixtures.richDocument(styled("Big Title", "Body words here"), type: .rtf, name: "h.rtf", in: root)
        let md = try await textOf(run(src, .convert(.md), caps: .none).outputs[0])
        #expect(md.hasPrefix("# Big Title"))
        #expect(md.contains("Body words here"))
    }

    @Test func plainTextToMarkdownIsVerbatim() async throws {
        let src = Fixtures.text("a * b\nline two\n", "p.txt", in: root)
        let md = try await textOf(run(src, .convert(.md), caps: .none).outputs[0])
        #expect(md == "a * b\nline two\n")
    }

    @Test func epubHasOneChapterFromHtmlBody() async throws {
        let src = Fixtures.richDocument(styled("Heading", "Fish & chips <ok> ü"), type: .rtf, name: "book.rtf", in: root)
        let o = try await run(src, .convert(.epub), caps: .none).outputs[0]
        let list = try await Fixtures.unzipList(o)
        #expect(list.filter { $0.hasPrefix("OEBPS/chapter-") } == ["OEBPS/chapter-1.xhtml"])
        let chapter = try await Fixtures.unzipRead(o, "OEBPS/chapter-1.xhtml")
        #expect(XMLDocumentCheck.isWellFormed(chapter))
        #expect(chapter.contains("Fish &amp; chips &lt;ok&gt; ü"))
        #expect(!chapter.contains("<style"))
        let opf = try await Fixtures.unzipRead(o, "OEBPS/content.opf")
        #expect(opf.contains("<dc:title>book</dc:title>"))
    }

    @Test func markdownListsStayOneListInHtmlAndEpub() async throws {
        let src = Fixtures.text("Intro\n\n- one\n- two\n\n1. first\n2. second\n\n```\nlet x = 1\nlet y = 2\n```\n", "l.md", in: root)
        let html = try String(contentsOf: try await run(src, .convert(.html), caps: .none).outputs[0], encoding: .utf8)
        #expect(html.components(separatedBy: "<ul").count == 2 && html.components(separatedBy: "<ol").count == 2)
        let epub = try await run(src, .convert(.epub), caps: .none).outputs[0]
        let chapter = try await Fixtures.unzipRead(epub, "OEBPS/chapter-1.xhtml")
        #expect(XMLDocumentCheck.isWellFormed(chapter))
        #expect(chapter.contains("<li") && chapter.contains("one") && chapter.contains("second"))
        #expect(chapter.contains("let x = 1") && chapter.contains("let y = 2"))
        #expect(!chapter.contains("class=\""), "classes need the head's style block, which a chapter lacks")
    }

    @Test func htmlOutputIsHtmlDocument() async throws {
        let o = try await run(Fixtures.docx("Hello <Orbit>", in: root), .convert(.html), caps: .none).outputs[0]
        let html = try String(contentsOf: o, encoding: .utf8)
        #expect(html.contains("<html") && html.contains("Hello &lt;Orbit&gt;"))
    }

    // MARK: Inputs

    @Test(arguments: ["rtf", "doc", "html"])
    func readsOtherFormats(ext: String) async throws {
        let attributed = NSAttributedString(string: "Hello \(ext) world", attributes: [.font: NSFont.systemFont(ofSize: 12)])
        let type: NSAttributedString.DocumentType = ext == "rtf" ? .rtf : ext == "doc" ? .docFormat : .html
        let src = Fixtures.richDocument(attributed, type: type, name: "in.\(ext)", in: root)
        let o = try await run(src, .convert(.txt), caps: .none).outputs[0]
        #expect(try await textOf(o).contains("Hello \(ext) world"))
    }

    @Test func readsRTFDPackage() async throws {
        let src = Fixtures.rtfd("Packaged text", in: root)
        #expect(DroppedItem(url: src).category == .document)
        let o = try await run(src, .convert(.txt), caps: .none).outputs[0]
        #expect(try await textOf(o).contains("Packaged text"))
    }

    @Test func plainTextEncodingsAreDetected() async throws {
        let utf16 = root.appending(path: "u16.txt")
        try "Grüße, Orbit".data(using: .utf16)!.write(to: utf16, options: .withoutOverwriting)
        #expect(try await RichText.read(DroppedItem(url: utf16), iwork: nil).string == "Grüße, Orbit")
        let latin1 = root.appending(path: "l1.txt")
        try "Grüße, Orbit".data(using: .isoLatin1)!.write(to: latin1, options: .withoutOverwriting)
        #expect(try await RichText.read(DroppedItem(url: latin1), iwork: nil).string == "Grüße, Orbit")
    }

    @Test func textClipping() async throws {
        #expect(try await RichText.read(DroppedItem(url: Fixtures.textClipping("Clip text", in: root)), iwork: nil).string == "Clip text")
    }

    @Test func textClippingWithDataValue() async throws {
        let url = Fixtures.textClipping("Clip ü data", in: root, name: "D.textClipping", asData: true)
        #expect(try await RichText.read(DroppedItem(url: url), iwork: nil).string == "Clip ü data")
    }

    @Test func textClippingConverts() async throws {
        let o = try await run(Fixtures.textClipping("Clip text", in: root), .convert(.pdf), caps: .none).outputs[0]
        #expect(try await textOf(o).contains("Clip text"))
    }

    @Test func malformedClippingFailsCleanly() async throws {
        let bad = Fixtures.file("Bad.textClipping", "not a plist", in: root)
        await #expect(throws: OrbitError.self) { try await RichText.read(DroppedItem(url: bad), iwork: nil) }
    }

    @Test func weirdFileName() async throws {
        let src = Fixtures.docx("Odd name", in: root, name: Self.weird)
        let o = try await run(src, .convert(.txt), caps: .none).outputs[0]
        #expect(o.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(try await textOf(o).contains("Odd name"))
    }

    @Test func sourceIsNeverTouched() async throws {
        let src = Fixtures.docx("Keep me", in: root)
        let before = Fixtures.bytes(src)
        _ = try await run(src, .convert(.pdf), caps: .none)
        #expect(Fixtures.bytes(src) == before)
    }

    // MARK: Pages

    @Test func pagesOutputNeedsPages() async throws {
        let src = Fixtures.docx("Hello", in: root)
        await #expect(throws: OrbitError.helperMissing(.pages)) { try await self.run(src, .convert(.pages), caps: .none) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "doc-converted.pages").path))
    }

    @Test func pagesInputNeedsPages() async throws {
        let src = Fixtures.file("x.pages", "not really", in: root)
        await #expect(throws: OrbitError.helperMissing(.pages)) { try await self.run(src, .convert(.txt), caps: .none) }
    }

    @Test func bridgeExportNeedsTheApp() async throws {
        let bridge = IWorkBridge(capabilities: .none)
        await #expect(throws: OrbitError.helperMissing(.pages)) {
            try await bridge.export(self.root.appending(path: "a.docx"), app: .pages, format: .pdf, to: self.root.appending(path: "a.pdf"))
        }
    }

    @Test func bridgeRefusesToOverwrite() async throws {
        let bridge = IWorkBridge(capabilities: .everything)
        let existing = Fixtures.file("a.pdf", "mine", in: root)
        await #expect(throws: OrbitError.self) {
            try await bridge.export(self.root.appending(path: "a.docx"), app: .pages, format: .pdf, to: existing)
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine")
    }

    /// The iWork app only ever opens a private copy, so the user's own open window (and file) is
    /// never exported from, re-pointed by Save As, or closed without saving.
    @Test func bridgeOpensAPrivateCopy() async throws {
        let deck = Fixtures.file("deck.key/Index.zip", "slides", in: root).deletingLastPathComponent()
        let seen = SeenArguments()
        let bridge = IWorkBridge(capabilities: .everything, runScript: { script, argv in
            let copy = URL(fileURLWithPath: argv[0])
            seen.record(argv: argv, script: script,
                        content: try? String(contentsOf: copy.appending(path: "Index.zip"), encoding: .utf8))
            return ""
        })
        try await bridge.export(deck, app: .keynote, format: .pdf, to: root.appending(path: "deck.pdf"))
        let argv = try #require(seen.argv)
        #expect(argv[0] != deck.path)
        #expect(URL(fileURLWithPath: argv[0]).lastPathComponent == "deck.key")
        #expect(seen.content == "slides")
        #expect(argv[1] == root.appending(path: "deck.pdf").path)
        #expect(!FileManager.default.fileExists(atPath: argv[0]), "the private copy is removed afterwards")
        #expect(seen.script?.contains("with timeout of 1800 seconds") == true)
        #expect(try String(contentsOf: deck.appending(path: "Index.zip"), encoding: .utf8) == "slides")
    }

    private final class SeenArguments: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (argv: [String], script: String, content: String?)?
        func record(argv: [String], script: String, content: String?) { lock.withLock { stored = (argv, script, content) } }
        var argv: [String]? { lock.withLock { stored?.argv } }
        var script: String? { lock.withLock { stored?.script } }
        var content: String? { lock.withLock { stored?.content } }
    }

    @Test func pagesScript() {
        let s = IWorkBridge.script(app: .pages, bundleID: "com.apple.Pages", format: .pdf)
        #expect(s.contains("tell application id \"com.apple.Pages\"") && s.contains("as PDF") && s.contains("on run argv") && !s.contains("/Users"))
    }

    @Test func scriptsTakePathsOnlyFromArgv() {
        let cases: [(Helper, String, IWorkFormat, String)] = [
            (.pages, "com.apple.Pages", .pdf, "as PDF"),
            (.pages, "com.apple.Pages", .word, "as Microsoft Word"),
            (.pages, "com.apple.Pages", .pages, "save theDoc in"),
            (.keynote, "com.apple.Keynote", .powerpoint, "as Microsoft PowerPoint"),
            (.keynote, "com.apple.Keynote", .keynote, "save theDoc in"),
            (.keynote, "com.apple.Keynote", .slideImages(.png), "as slide images with properties {image format:PNG}"),
            (.keynote, "com.apple.Keynote", .slideImages(.jpg), "as slide images with properties {image format:JPEG}"),
            (.numbers, "com.apple.Numbers", .excel, "as Microsoft Excel"),
            (.numbers, "com.apple.Numbers", .csv, "as CSV"),
            (.numbers, "com.apple.Numbers", .numbers, "save theDoc in"),
            (.numbers, "com.apple.Numbers", .pdf, "as PDF"),
        ]
        for (app, id, format, fragment) in cases {
            let s = IWorkBridge.script(app: app, bundleID: id, format: format)
            #expect(s.contains("tell application id \"\(id)\""), "\(id) \(format)")
            #expect(s.contains(fragment), "\(format) should contain \(fragment)")
            #expect(s.contains("item 1 of argv") && s.contains("item 2 of argv"))
            #expect(s.contains("close theDoc saving no"))
            #expect(!s.contains("/"), "no path-like text in \(format)")
        }
        let older = IWorkBridge.script(app: .pages, bundleID: "com.apple.iWork.Pages", format: .pdf)
        #expect(older.contains("tell application id \"com.apple.iWork.Pages\""))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_IWORK_TESTS"] == "1"))
    func viaPages() async throws {
        let o = try await run(Fixtures.docx("Hello Orbit", in: root), .convert(.pdf), caps: Fixtures.caps).outputs[0]
        #expect(PDFDocument(url: o)!.string!.contains("Hello Orbit"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_IWORK_TESTS"] == "1"))
    func toPages() async throws {
        let o = try await run(Fixtures.docx("Hello Orbit", in: root), .convert(.pages), caps: Fixtures.caps).outputs[0]
        #expect(o.pathExtension == "pages")
    }
}
