import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// The PDF tools: compress, merge, split, organize, redact and metadata removal.
///
/// Every tool writes a new file at `to` (a name the job reserved) and never touches its sources.
public enum PDFTools {
    // MARK: Compress

    private enum Level: CaseIterable {
        /// Embedded images downsampled for screen.
        case light
        /// Light, and images re-encoded as JPEG.
        case medium
        /// Every page flattened to a 100 DPI JPEG (quality 0.6). The text is no longer text.
        case strong
        /// Every page flattened to a 72 DPI JPEG (quality 0.5): only used to reach a "fit under" size.
        case smallest
    }

    /// Writes a compressed copy of `src` to `to` and returns its size in bytes.
    ///
    /// Tiers: light and medium keep the text; strong flattens the pages to pictures. "Fit under" tries
    /// light, medium, strong and then a 72 DPI flatten, and keeps the first that fits. Throws
    /// `.targetTooSmall` (and writes nothing) when none does.
    @discardableResult
    public static func compress(_ src: URL, target: CompressTarget, to: URL) throws -> Int64 {
        let levels: [Level]
        var limit: Int64?
        switch target {
        case .tier(.light): levels = [.light]
        case .tier(.medium): levels = [.medium]
        case .tier(.strong): levels = [.strong]
        case .fitUnder(let bytes):
            levels = Level.allCases
            limit = bytes
        }
        try refuseOverwrite(to)
        return try withScratch { scratch in
            let candidate = scratch.appending(path: "candidate.pdf", directoryHint: .notDirectory)
            for level in levels {
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: candidate)
                try attempt(level, src: src, into: candidate)
                let size = try fileSize(candidate)
                if let limit, size > limit { continue }
                try FileManager.default.moveItem(at: candidate, to: to)
                return size
            }
            throw OrbitError.targetTooSmall("Can't get this PDF under \(limit ?? 0) bytes.")
        }
    }

    private static func attempt(_ level: Level, src: URL, into out: URL) throws {
        switch level {
        case .light:
            try write(try PDFRender.open(src), options: [.optimizeImagesForScreenOption: true], to: out)
        case .medium:
            try write(try PDFRender.open(src),
                      options: [.optimizeImagesForScreenOption: true, .saveImagesAsJPEGOption: true], to: out)
        case .strong:
            try write(try flattened(src, dpi: 100, quality: 0.6), options: [:], to: out)
        case .smallest:
            try write(try flattened(src, dpi: 72, quality: 0.5), options: [:], to: out)
        }
    }

    /// A document whose pages are JPEG pictures of `src`'s pages, one at a time so memory stays at one page.
    private static func flattened(_ src: URL, dpi: Double, quality: Double) throws -> PDFDocument {
        let document = try PDFRender.open(src)
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFRender.unreadable }
                let picture = try jpegImage(try PDFRender.render(page, dpi: dpi), quality: quality)
                let single = try PDFRender.imagePage(picture, size: PDFRender.displaySize(page))
                try append(single, to: result)
            }
        }
        return result
    }

    /// The image encoded as JPEG and decoded again as a JPEG-backed image, so a PDF keeps the JPEG stream.
    private static func jpegImage(_ image: CGImage, quality: Double) throws -> CGImage {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageBitmap.failure
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination),
              let provider = CGDataProvider(data: data as CFData),
              let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true,
                                 intent: .defaultIntent) else { throw ImageBitmap.failure }
        return jpeg
    }

    // MARK: Merge and split

    /// All pages of `sources`, in order, as one PDF. Returns the page count.
    @discardableResult
    public static func merge(_ sources: [URL], to: URL) throws -> Int {
        guard !sources.isEmpty else { throw OrbitError.unsupported("There are no PDFs to merge.") }
        try refuseOverwrite(to)
        let result = PDFDocument()
        var opened: [PDFDocument] = []
        for source in sources {
            try Task.checkCancellation()
            let document = try PDFRender.open(source)
            opened.append(document)
            for index in 0..<document.pageCount {
                guard let page = document.page(at: index) else { throw PDFRender.unreadable }
                try append(page, to: result)
            }
        }
        try save(result, to: to)
        withExtendedLifetime(opened) {}
        return result.pageCount
    }

    /// One PDF per range, written to the matching `outputs` URL. Ranges are 1-based and inclusive.
    public static func split(_ src: URL, ranges: [ClosedRange<Int>], outputs: [URL]) throws {
        guard !ranges.isEmpty, ranges.count == outputs.count else {
            throw OrbitError.unsupported("Choose the pages to split out.")
        }
        let count = try PDFRender.open(src).pageCount
        for range in ranges where range.lowerBound < 1 || range.upperBound > count {
            throw OrbitError.unsupported("That page range isn't in this PDF. It has \(count) page\(count == 1 ? "" : "s").")
        }
        for (range, output) in zip(ranges, outputs) {
            try Task.checkCancellation()
            let document = try PDFRender.open(src)
            let part = PDFDocument()
            for number in range {
                guard let page = document.page(at: number - 1) else { throw PDFRender.unreadable }
                try append(page, to: part)
            }
            try save(part, to: output)
            withExtendedLifetime(document) {}
        }
    }

    // MARK: Organize

    /// The pages listed in `pages`, in that order, each rotated by its quarter turns (clockwise).
    /// A page left out is deleted; one listed twice is duplicated.
    public static func organize(_ src: URL, pages: [PageOp], to: URL) throws {
        guard !pages.isEmpty else { throw OrbitError.unsupported("Keep at least one page.") }
        let document = try PDFRender.open(src)
        for op in pages where op.sourceIndex < 0 || op.sourceIndex >= document.pageCount {
            throw OrbitError.unsupported("That page isn't in this PDF.")
        }
        try refuseOverwrite(to)
        let result = PDFDocument()
        for op in pages {
            try Task.checkCancellation()
            guard let page = document.page(at: op.sourceIndex) else { throw PDFRender.unreadable }
            let copy = try append(page, to: result)
            copy.rotation = (((copy.rotation + 90 * op.quarterTurns) % 360) + 360) % 360
        }
        try save(result, to: to)
        withExtendedLifetime(document) {}
    }

    // MARK: Redact

    /// True redaction. Each page that has a redaction is drawn at `dpi`, the rectangles are filled with
    /// solid black in the pixels, and the page is replaced by that picture: no text layer, no content
    /// stream, nothing underneath. Pages without a redaction are copied unchanged.
    public static func redact(_ src: URL, redactions: [PDFRedaction], dpi: Int, to: URL) throws {
        let document = try PDFRender.open(src)
        var rectsByPage: [Int: [CGRect]] = [:]
        for redaction in redactions {
            guard redaction.pageIndex >= 0, redaction.pageIndex < document.pageCount else {
                throw OrbitError.unsupported("A redaction is on a page that isn't in this PDF.")
            }
            let usable = redaction.rects.filter { !$0.isNull && !$0.isEmpty && $0.width.isFinite && $0.height.isFinite }
            if !usable.isEmpty { rectsByPage[redaction.pageIndex, default: []] += usable }
        }
        guard !rectsByPage.isEmpty else { throw OrbitError.unsupported("There is nothing to redact.") }
        try refuseOverwrite(to)

        let result = PDFDocument()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            try autoreleasepool {
                guard let page = document.page(at: index) else { throw PDFRender.unreadable }
                if let rects = rectsByPage[index] {
                    let flat = try PDFRender.render(page, dpi: Double(max(dpi, 72)), blackRects: rects)
                    try append(try PDFRender.imagePage(flat, size: PDFRender.displaySize(page)), to: result)
                } else {
                    try append(page, to: result)
                }
            }
        }
        try save(result, to: to)
        withExtendedLifetime(document) {}
    }

    // MARK: Metadata

    /// The same pages with no document information (author, title, dates, keywords) and no XMP metadata.
    /// The pages are copied into a new document, which is what guarantees nothing of the old catalog
    /// survives. Outlines and named destinations are not carried over.
    public static func stripMetadata(_ src: URL, to: URL) throws {
        let document = try PDFRender.open(src)
        try refuseOverwrite(to)
        let result = PDFDocument()
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw PDFRender.unreadable }
            try append(page, to: result)
        }
        result.documentAttributes = [:]
        try save(result, to: to)
        withExtendedLifetime(document) {}
    }

    // MARK: Helpers

    /// Appends a copy of `page` to `document`.
    @discardableResult
    private static func append(_ page: PDFPage, to document: PDFDocument) throws -> PDFPage {
        guard let copy = page.copy() as? PDFPage else { throw PDFRender.unreadable }
        document.insert(copy, at: document.pageCount)
        return copy
    }

    private static func append(_ single: PDFDocument, to document: PDFDocument) throws {
        guard let page = single.page(at: 0) else { throw PDFRender.unreadable }
        try append(page, to: document)
    }

    private static func refuseOverwrite(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw OrbitError.unsupported("Refusing to overwrite existing file \(url.lastPathComponent).")
        }
    }

    private static func fileSize(_ url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }

    /// Writes `document` beside a scratch name and moves it to `to`, so a failure leaves no partial file.
    private static func save(_ document: PDFDocument, options: [PDFDocumentWriteOption: Any] = [:], to: URL) throws {
        try refuseOverwrite(to)
        try withScratch { scratch in
            let staged = scratch.appending(path: "out.pdf", directoryHint: .notDirectory)
            try write(document, options: options, to: staged)
            try FileManager.default.moveItem(at: staged, to: to)
        }
    }

    private static func write(_ document: PDFDocument, options: [PDFDocumentWriteOption: Any], to url: URL) throws {
        guard document.write(to: url, withOptions: options.isEmpty ? nil : options) else {
            throw OrbitError.unsupported("Orbit couldn't write this PDF.")
        }
    }

    private static func withScratch<T>(_ body: (URL) throws -> T) throws -> T {
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "orbit-pdf-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        return try body(scratch)
    }
}
