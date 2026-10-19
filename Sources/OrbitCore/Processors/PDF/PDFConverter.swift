import AppKit
import CoreGraphics
import Foundation
import PDFKit

/// Page access and rendering shared by the PDF converter and the PDF tools.
enum PDFRender {
    static let unreadable = OrbitError.unsupported("Orbit couldn't read this PDF.")

    /// Opens a PDF, refusing password-protected ones with a clear message.
    static func open(_ url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else { throw unreadable }
        if document.isLocked {
            throw OrbitError.unsupported("This PDF is password-protected. Unlock it first.")
        }
        return document
    }

    /// The page's size in points as it is shown (crop box, with the page's rotation applied).
    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        return page.rotation % 180 == 0 ? box.size : CGSize(width: box.height, height: box.width)
    }

    /// The page drawn on white at `dpi`, optionally with solid black rectangles on top. `blackRects` are
    /// in page space (points, origin at bottom left, as PDFKit reports selection bounds). Each is
    /// grown outward to whole pixels, so no anti-aliased edge of the covered content survives.
    static func render(_ page: PDFPage, dpi: Double, blackRects: [CGRect] = []) throws -> CGImage {
        let size = displaySize(page)
        let width = max(1, Int((size.width * dpi / 72).rounded()))
        let height = max(1, Int((size.height * dpi / 72).rounded()))
        guard let pageRef = page.pageRef else { throw unreadable }
        let context = try ImageBitmap.makeContext(width: width, height: height, opaque: true)
        let canvas = CGRect(x: 0, y: 0, width: width, height: height)
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(canvas)

        // getDrawingTransform only ever shrinks a page to fit, so it maps the page at 1 point = 1 unit
        // (crop box origin and rotation handled) and the pixel scale is applied on top.
        let natural = pageRef.getDrawingTransform(.cropBox, rect: CGRect(origin: .zero, size: size),
                                                  rotate: 0, preserveAspectRatio: true)
        let transform = natural.concatenating(CGAffineTransform(scaleX: CGFloat(width) / size.width,
                                                                y: CGFloat(height) / size.height))
        context.saveGState()
        context.concatenate(transform)
        context.drawPDFPage(pageRef)
        context.restoreGState()

        if !blackRects.isEmpty {
            context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))
            context.setShouldAntialias(false)
            for rect in blackRects {
                context.fill(rect.applying(transform).integral)
            }
        }
        guard let image = context.makeImage() else { throw ImageBitmap.failure }
        return image
    }

    /// A one-page PDF document whose page is `image` filling a `size`-point page.
    static func imagePage(_ image: CGImage, size: CGSize) throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(origin: .zero, size: size)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw unreadable }
        context.beginPDFPage(nil)
        context.draw(image, in: box)
        context.endPDFPage()
        context.closePDF()
        guard let document = PDFDocument(data: data as Data), document.pageCount == 1 else { throw unreadable }
        return document
    }

    static func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
    }

    /// The text of each page, line endings normalized to "\n". With `columnGaps`, a space that is
    /// really a wide horizontal gap (roughly 2 em or wider, as between table columns) comes out as a tab,
    /// because PDFKit otherwise reports every gap as a single space.
    static func pageTexts(_ document: PDFDocument, columnGaps: Bool = false) -> [String] {
        (0..<document.pageCount).map { index in
            guard let page = document.page(at: index), let raw = page.string else { return "" }
            let text = columnGaps ? tabbingWideGaps(raw, on: page) : raw
            return lines(text).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func tabbingWideGaps(_ text: String, on page: PDFPage) -> String {
        let characters = text as NSString
        var result = ""
        var segmentStart = 0
        for index in 0..<characters.length where characters.character(at: index) == 0x20 {
            result += characters.substring(with: NSRange(location: segmentStart, length: index - segmentStart))
            // A space's own height is unreliable (often 0), so the type size is judged from the
            // tallest of the three characters before it.
            let typeHeight = (max(0, index - 3)..<index).map { page.characterBounds(at: $0).height }.max() ?? 0
            result += page.characterBounds(at: index).width > max(typeHeight, 6) * 2 ? "\t" : " "
            segmentStart = index + 1
        }
        return result + characters.substring(from: segmentStart)
    }

    /// Throws when no page has any text (a scanned PDF), so a text output is never an empty file.
    static func requireText(_ texts: [String]) throws {
        if texts.allSatisfy({ $0.isEmpty }) {
            throw OrbitError.unsupported("This PDF has no text to extract. It may be scanned pages.")
        }
    }
}

/// PDF to images, text, Markdown, Word, EPUB, PowerPoint and Excel.
public enum PDFConverter {
    /// Renders every page onto white at `dpi` and writes page `i` to `outputs[i]` (JPG or PNG).
    public static func images(_ src: URL, format: OutputFormat, dpi: Int, quality: Double = 0.85, to outputs: [URL]) throws {
        guard format == .jpg || format == .png else {
            throw OrbitError.unsupported("Orbit can't turn a PDF into \(format.label) images.")
        }
        let document = try PDFRender.open(src)
        guard outputs.count == document.pageCount else {
            throw OrbitError.unsupported("Orbit couldn't plan the output files for this PDF.")
        }
        let dots = Double(max(dpi, 1))
        let properties: [CFString: Any] = [kCGImagePropertyDPIWidth: dots, kCGImagePropertyDPIHeight: dots]
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFRender.unreadable }
                let image = try PDFRender.render(page, dpi: dots)
                try ImageFile.write(image, to: outputs[index], format: format,
                                    quality: format == .jpg ? quality : nil, properties: properties)
            }
        }
    }

    /// All the text, pages separated by a blank line.
    public static func text(_ src: URL) throws -> String {
        let texts = PDFRender.pageTexts(try PDFRender.open(src))
        try PDFRender.requireText(texts)
        return texts.joined(separator: "\n\n") + "\n"
    }

    /// Markdown per page (headings by font size, bold, italic, lists), pages joined by a rule.
    public static func markdown(_ src: URL) throws -> String {
        let document = try PDFRender.open(src)
        try PDFRender.requireText(PDFRender.pageTexts(document))
        let pages = (0..<document.pageCount).map { index -> String in
            guard let text = document.page(at: index)?.attributedString else { return "" }
            return MarkdownWriter.markdown(from: text).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pages.joined(separator: "\n\n---\n\n") + "\n"
    }

    /// The text with its fonts, pages separated by a blank line.
    public static func attributed(_ src: URL) throws -> NSAttributedString {
        let document = try PDFRender.open(src)
        try PDFRender.requireText(PDFRender.pageTexts(document))
        let result = NSMutableAttributedString()
        for index in 0..<document.pageCount {
            if index > 0 { result.append(NSAttributedString(string: "\n\n", attributes: [.font: RichText.bodyFont])) }
            if let page = document.page(at: index)?.attributedString {
                let text = NSMutableAttributedString(attributedString: page)
                while text.string.hasSuffix("\n") || text.string.hasSuffix("\r") {
                    text.deleteCharacters(in: NSRange(location: text.length - 1, length: 1))
                }
                result.append(text)
            }
        }
        return result
    }

    /// A Word document with the PDF's text (not its layout).
    public static func docx(_ src: URL, to: URL) throws {
        let text = try attributed(src)
        do {
            let data = try text.data(from: NSRange(location: 0, length: text.length),
                                     documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            try data.write(to: to, options: .withoutOverwriting)
        } catch let error as OrbitError {
            throw error
        } catch {
            Log.error("Writing docx from \(src.lastPathComponent) failed: \(error.localizedDescription)")
            throw OrbitError.unsupported("Orbit couldn't write that document.")
        }
    }

    /// One slide per page: each page as a 150 DPI picture on a slide as big as the first page in points.
    public static func pptx(_ src: URL, to: URL) async throws {
        let document = try PDFRender.open(src)
        guard let first = document.page(at: 0) else { throw PDFRender.unreadable }
        let slideSize = PDFRender.displaySize(first)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "orbit-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }

        var slides: [URL] = []
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            let url = scratch.appending(path: "slide-\(index + 1).png", directoryHint: .notDirectory)
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFRender.unreadable }
                let image = try PDFRender.render(page, dpi: 150)
                try ImageFile.write(image, to: url, format: .png, quality: nil, properties: nil)
            }
            slides.append(url)
        }
        try await PPTXWriter.write(slideImages: slides, slideSize: slideSize, to: to)
    }

    /// One row per text line; columns split on a tab or two or more spaces.
    public static func xlsx(_ src: URL, to: URL) async throws {
        let texts = PDFRender.pageTexts(try PDFRender.open(src), columnGaps: true)
        try PDFRender.requireText(texts)
        let separator = try Regex("\\t| {2,}")
        var rows: [[String]] = []
        for text in texts {
            for line in PDFRender.lines(text) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                rows.append(trimmed.split(separator: separator, omittingEmptySubsequences: true)
                    .map { $0.trimmingCharacters(in: .whitespaces) })
            }
        }
        try await XLSXWriter.write(rows: rows, sheetName: src.deletingPathExtension().lastPathComponent, to: to)
    }

    /// One chapter per page, each line a paragraph.
    public static func epub(_ src: URL, to: URL) async throws {
        let texts = PDFRender.pageTexts(try PDFRender.open(src))
        try PDFRender.requireText(texts)
        let chapters = texts.enumerated().map { index, text -> EPUBChapter in
            let body = PDFRender.lines(text).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }.map { "<p>\(XMLText.escape($0))</p>" }.joined()
            return EPUBChapter(title: "Page \(index + 1)", xhtmlBody: body)
        }
        try await EPUBWriter.write(title: src.deletingPathExtension().lastPathComponent, author: nil,
                                   chapters: chapters, to: to)
    }
}
