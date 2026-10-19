import AppKit
import Foundation

/// Converts word-processing documents (docx, doc, pages, rtf, rtfd, txt, md, html, text clippings)
/// to pdf, docx, txt, md, html, epub and pages.
///
/// PDF from docx, doc and pages goes through Pages when it is installed (better fidelity); otherwise
/// Orbit lays the text out itself. Pages output always needs Pages.
public struct DocumentProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.pdf, .docx, .txt, .md, .html, .epub, .pages]
    private static let pagesNative: Set<String> = ["docx", "doc", "pages"]
    private static let plainSources: Set<String> = ["txt", "textclipping"]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .document }),
              case .convert(let format) = request.action else { return false }
        return Self.outputs.contains(format)
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        guard case .convert(let format) = request.action else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        let bridge = IWorkBridge(capabilities: context.capabilities)
        var outputs: [URL] = []
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            try await convert(item, to: format, output: output, bridge: bridge, context: context)
            outputs.append(output)
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        return ProcessorOutput(outputs: outputs)
    }

    private func convert(_ item: DroppedItem, to format: OutputFormat, output: URL,
                         bridge: IWorkBridge, context: JobContext) async throws {
        switch format {
        case .pdf:
            try await toPDF(item, output: output, bridge: bridge)
        case .pages:
            try await toPages(item, output: output, bridge: bridge)
        case .docx:
            let text = try await RichText.read(item, iwork: bridge)
            try write(try Self.data(text, .officeOpenXML), to: output)
        case .txt:
            let text = try await RichText.read(item, iwork: bridge)
            try write(Data(text.string.replacingOccurrences(of: "\u{FFFC}", with: "").utf8), to: output)
        case .md:
            let text = try await RichText.read(item, iwork: bridge)
            // Plain text is already valid Markdown: keep it exactly as written.
            let markdown = Self.plainSources.contains(item.formatKey) ? text.string : MarkdownWriter.markdown(from: text)
            try write(Data(markdown.utf8), to: output)
        case .html:
            let text = try await RichText.read(item, iwork: bridge)
            try write(try await Self.htmlData(text), to: output)
        case .epub:
            let text = try await RichText.read(item, iwork: bridge)
            let html = try await Self.htmlData(text)
            let title = item.url.deletingPathExtension().lastPathComponent
            let chapter = EPUBChapter(title: title, xhtmlBody: XHTMLBody.make(fromHTML: html, plainText: text.string))
            try await EPUBWriter.write(title: title, author: nil, chapters: [chapter], to: output)
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    // MARK: PDF and Pages

    private func toPDF(_ item: DroppedItem, output: URL, bridge: IWorkBridge) async throws {
        let key = item.formatKey
        if Self.pagesNative.contains(key), bridge.capabilities.has(.pages) {
            // Only a file that appears during the export can be removed: never one that was already there.
            let existedBefore = FileManager.default.fileExists(atPath: output.path)
            do {
                try await bridge.export(item.url, app: .pages, format: .pdf, to: output)
                return
            } catch {
                // A Pages file has no other reader; for docx and doc, fall back to Orbit's own layout.
                if key == "pages" || existedBefore || error is CancellationError || (error as? OrbitError) == .cancelled { throw error }
                Log.error("Pages could not export \(item.url.lastPathComponent) to PDF, laying it out in Orbit instead: \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: output)
            }
        }
        let text = try await RichText.read(item, iwork: bridge)
        try RichText.writePDF(text, to: output, paper: RichText.paperSize(for: .current))
    }

    private func toPages(_ item: DroppedItem, output: URL, bridge: IWorkBridge) async throws {
        guard bridge.capabilities.has(.pages) else { throw OrbitError.helperMissing(.pages) }
        if item.formatKey == "docx" || item.formatKey == "doc" {
            try await bridge.export(item.url, app: .pages, format: .pages, to: output)
            return
        }
        // Everything else becomes a temporary docx that Pages opens and saves as a Pages file.
        let text = try await RichText.read(item, iwork: bridge)
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "orbit-docx-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let docx = scratch.appending(path: "document.docx", directoryHint: .notDirectory)
        try write(try Self.data(text, .officeOpenXML), to: docx)
        try await bridge.export(docx, app: .pages, format: .pages, to: output)
    }

    // MARK: Writing

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
    }

    private static func data(_ text: NSAttributedString, _ type: NSAttributedString.DocumentType) throws -> Data {
        do {
            return try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        } catch {
            Log.error("Writing \(type.rawValue) failed: \(error.localizedDescription)")
            throw OrbitError.unsupported("Orbit couldn't write that document.")
        }
    }

    /// HTML export goes through the main thread, as HTML import does.
    private static func htmlData(_ text: NSAttributedString) async throws -> Data {
        let box = MainThreadBox(NSAttributedString(attributedString: text))
        return try await MainActor.run {
            try Self.data(box.value, .html)
        }
    }
}

/// Turns AppKit's HTML export into the inside of an XHTML `<body>`.
enum XHTMLBody {
    /// AppKit writes styling as classes backed by a `<style>` block in `<head>`. The head does not
    /// travel into an EPUB chapter, so each class is turned back into an inline `style`.
    static func make(fromHTML html: Data, plainText: String) -> String {
        guard let document = try? XMLDocument(data: html, options: [.documentTidyHTML]),
              let body = (try? document.nodes(forXPath: "//body"))?.first as? XMLElement else {
            return fallback(plainText)
        }
        let rules = cssRules(in: (try? document.nodes(forXPath: "//style")) ?? [])
        inline(rules, in: body)
        let result = (body.children ?? []).map { $0.xmlString(options: [.nodeCompactEmptyElement]) }.joined()
        return result.isEmpty ? fallback(plainText) : result
    }

    private static func fallback(_ text: String) -> String {
        let paragraphs = text.replacingOccurrences(of: "\u{FFFC}", with: "")
            .components(separatedBy: .newlines)
        return paragraphs.map { "<p>\(XMLText.escape($0))</p>" }.joined()
    }

    /// `tag.class` → declarations, from rules such as `p.p1 {margin: 0.0px; font: 12.0px Helvetica}`.
    private static func cssRules(in styles: [XMLNode]) -> [String: String] {
        guard let pattern = try? NSRegularExpression(pattern: "([A-Za-z0-9]+)\\.([A-Za-z0-9_-]+)\\s*\\{([^}]*)\\}") else { return [:] }
        var rules: [String: String] = [:]
        for style in styles {
            let css = style.stringValue ?? ""
            let whole = NSRange(location: 0, length: (css as NSString).length)
            for m in pattern.matches(in: css, range: whole) {
                let tag = (css as NSString).substring(with: m.range(at: 1)).lowercased()
                let name = (css as NSString).substring(with: m.range(at: 2))
                let declarations = (css as NSString).substring(with: m.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
                rules["\(tag).\(name)"] = declarations
            }
        }
        return rules
    }

    private static func inline(_ rules: [String: String], in element: XMLElement) {
        for child in element.children ?? [] {
            guard let child = child as? XMLElement else { continue }
            if child.name?.lowercased() == "img" {
                // The picture is not packaged into the book, so a reference to it would dangle.
                element.removeChild(at: child.index)
                continue
            }
            if child.name?.lowercased() == "br" {
                // AppKit writes "<br>" followed by a newline, which would parse as content of the element.
                child.setChildren(nil)
            }
            if let classes = child.attribute(forName: "class")?.stringValue, let tag = child.name?.lowercased() {
                let declarations = classes.split(separator: " ").compactMap { rules["\(tag).\($0)"] }.joined(separator: "; ")
                child.removeAttribute(forName: "class")
                if !declarations.isEmpty {
                    let existing = child.attribute(forName: "style")?.stringValue
                    child.addAttribute(XMLNode.attribute(withName: "style", stringValue: [existing, declarations].compactMap { $0 }.joined(separator: "; ")) as! XMLNode)
                }
            }
            inline(rules, in: child)
        }
    }
}
