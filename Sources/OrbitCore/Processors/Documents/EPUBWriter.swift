import Foundation

public struct EPUBChapter: Sendable {
    public var title: String
    /// Well-formed XHTML for the inside of `<body>`. It is inserted as is; the caller owns its escaping.
    public var xhtmlBody: String

    public init(title: String, xhtmlBody: String) {
        self.title = title
        self.xhtmlBody = xhtmlBody
    }
}

/// Writes an EPUB 3 package.
public enum EPUBWriter {
    public static func write(title: String, author: String?, chapters: [EPUBChapter], to: URL) async throws {
        guard !chapters.isEmpty else { throw OrbitError.unsupported("There is nothing to put in the book.") }
        let decl = XMLText.declaration
        let xhtmlNS = "xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\""

        let container = "\(decl)<container version=\"1.0\" xmlns=\"urn:oasis:names:tc:opendocument:xmlns:container\">"
            + "<rootfiles><rootfile full-path=\"OEBPS/content.opf\" media-type=\"application/oebps-package+xml\"/></rootfiles></container>"

        var manifest = "<item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
        var spine = ""
        var tocItems = ""
        var chapterEntries: [(path: String, data: Data)] = []
        for (i, chapter) in chapters.enumerated() {
            let n = i + 1
            manifest += "<item id=\"chapter-\(n)\" href=\"chapter-\(n).xhtml\" media-type=\"application/xhtml+xml\"/>"
            spine += "<itemref idref=\"chapter-\(n)\"/>"
            tocItems += "<li><a href=\"chapter-\(n).xhtml\">\(XMLText.escape(chapter.title))</a></li>"
            let page = "\(decl)<html \(xhtmlNS) xml:lang=\"en\"><head><meta charset=\"utf-8\"/><title>\(XMLText.escape(chapter.title))</title></head>"
                + "<body>\(chapter.xhtmlBody)</body></html>"
            chapterEntries.append(("OEBPS/chapter-\(n).xhtml", Data(page.utf8)))
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let modified = formatter.string(from: Date())
        var meta = "<dc:identifier id=\"book-id\">urn:uuid:\(UUID().uuidString.lowercased())</dc:identifier>"
            + "<dc:title>\(XMLText.escape(title))</dc:title><dc:language>en</dc:language>"
        if let author, !author.isEmpty { meta += "<dc:creator>\(XMLText.escape(author))</dc:creator>" }
        meta += "<meta property=\"dcterms:modified\">\(modified)</meta>"
        let opf = "\(decl)<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">"
            + "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">\(meta)</metadata>"
            + "<manifest>\(manifest)</manifest><spine>\(spine)</spine></package>"

        let nav = "\(decl)<html \(xhtmlNS) xml:lang=\"en\"><head><meta charset=\"utf-8\"/><title>\(XMLText.escape(title))</title></head>"
            + "<body><nav epub:type=\"toc\" id=\"toc\"><h1>\(XMLText.escape(title))</h1><ol>\(tocItems)</ol></nav></body></html>"

        // `mimetype` has no trailing newline: readers compare it byte for byte.
        let entries: [(path: String, data: Data)] = [
            ("mimetype", Data("application/epub+zip".utf8)),
            ("META-INF/container.xml", Data(container.utf8)),
            ("OEBPS/content.opf", Data(opf.utf8)),
            ("OEBPS/nav.xhtml", Data(nav.utf8)),
        ] + chapterEntries
        try await ZipPackager.package(entries: entries, storedFirst: "mimetype", to: to)
    }
}
