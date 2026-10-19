import AppKit
import Foundation

/// Carries a value that is not `Sendable` (attributed text) to the main actor and back. Each box is
/// used by one task at a time and the value is never touched concurrently.
struct MainThreadBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// Reads word-processing files into attributed text and writes attributed text to a paginated PDF.
public enum RichText {
    // MARK: Paper

    private static let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE"]

    /// US Letter (612×792 pt) for the regions that use it, otherwise A4 (595×842 pt).
    public static func paperSize(for locale: Locale) -> CGSize {
        if let region = locale.region?.identifier, letterRegions.contains(region) {
            return CGSize(width: 612, height: 792)
        }
        return CGSize(width: 595, height: 842)
    }

    // MARK: Reading

    /// The document's text with its styling. Pages files go through Pages (`iwork`) to a temporary docx.
    public static func read(_ item: DroppedItem, iwork: IWorkBridge?) async throws -> NSAttributedString {
        let url = item.url
        switch item.formatKey {
        case "docx": return try load(url, .officeOpenXML)
        case "doc": return try load(url, .docFormat)
        case "rtf": return try load(url, .rtf)
        case "rtfd": return try load(url, .rtfd)
        case "html":
            // HTML import is WebKit-backed and must run on the main thread.
            return try await MainActor.run {
                MainThreadBox(try load(url, .html, extra: [.characterEncoding: String.Encoding.utf8.rawValue]))
            }.value
        case "txt": return plain(try decodeText(Data(contentsOf: url)))
        case "md": return try markdown(try decodeText(Data(contentsOf: url)))
        case "textclipping": return plain(try clippingText(url))
        case "pages": return try await readPages(url, iwork: iwork)
        default: throw OrbitError.unsupported("Orbit can't read this kind of document.")
        }
    }

    private static func load(_ url: URL, _ type: NSAttributedString.DocumentType,
                             extra: [NSAttributedString.DocumentReadingOptionKey: Any] = [:]) throws -> NSAttributedString {
        var options: [NSAttributedString.DocumentReadingOptionKey: Any] = [.documentType: type]
        options.merge(extra) { _, new in new }
        do {
            return try NSAttributedString(url: url, options: options, documentAttributes: nil)
        } catch {
            Log.error("Reading \(url.lastPathComponent) as \(type.rawValue) failed: \(error.localizedDescription)")
            throw OrbitError.unsupported("Orbit couldn't read \(url.lastPathComponent).")
        }
    }

    private static func readPages(_ url: URL, iwork: IWorkBridge?) async throws -> NSAttributedString {
        guard let iwork, iwork.capabilities.has(.pages) else { throw OrbitError.helperMissing(.pages) }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appending(path: "orbit-pages-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }
        let docx = scratch.appending(path: "converted.docx", directoryHint: .notDirectory)
        try await iwork.export(url, app: .pages, format: .word, to: docx)
        return try load(docx, .officeOpenXML)
    }

    // MARK: Plain text

    static let bodyFont: NSFont = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)

    private static func plain(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: bodyFont])
    }

    /// UTF-8 (strictly), UTF-16/32 by byte-order mark, then Windows-1252, then Latin-1 (which accepts any bytes).
    private static func decodeText(_ data: Data) -> String {
        let bytes = [UInt8](data.prefix(4))
        if bytes.starts(with: [0xFF, 0xFE, 0x00, 0x00]) || bytes.starts(with: [0x00, 0x00, 0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf32) { return s }
        if bytes.starts(with: [0xFF, 0xFE]) || bytes.starts(with: [0xFE, 0xFF]),
           let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) {
            return s.hasPrefix("\u{FEFF}") ? String(s.dropFirst()) : s
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1) ?? ""
    }

    // MARK: Text clippings

    /// A .textClipping is a property list whose `UTI-Data` dictionary maps type identifiers to the text,
    /// as a string or as bytes.
    private static func clippingText(_ url: URL) throws -> String {
        let failure = OrbitError.unsupported("Orbit couldn't read this text clipping.")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let types = plist["UTI-Data"] as? [String: Any] else { throw failure }
        for key in ["public.utf8-plain-text", "public.utf16-external-plain-text", "public.utf16-plain-text", "public.plain-text"] {
            if let s = types[key] as? String { return s }
            guard let bytes = types[key] as? Data else { continue }
            if key.hasPrefix("public.utf16"), let s = String(data: bytes, encoding: .utf16) { return s }
            return decodeText(bytes)
        }
        throw failure
    }

    // MARK: Markdown

    private struct Block {
        enum Kind { case paragraph, heading(Int), code, quote }
        var kind: Kind
        var listDepth: Int
        var ordered: Bool
        var marker: String?
        /// Outermost first. Items of one list share the same `NSTextList` so they export as one list.
        var lists: [NSTextList] = []
    }

    /// Markdown to styled text: headings by size, bold, italic, code, links, lists, block quotes.
    private static func markdown(_ source: String) throws -> NSAttributedString {
        let parsed: AttributedString
        do {
            parsed = try AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
        } catch {
            throw OrbitError.unsupported("Orbit couldn't read this Markdown file.")
        }

        let out = NSMutableAttributedString()
        var currentLeaf: Int?
        var paragraphStart = 0
        var currentBlock = Block(kind: .paragraph, listDepth: 0, ordered: false, marker: nil)
        var markedItems: Set<Int> = []
        var textLists: [Int: NSTextList] = [:]
        var currentRow: Int?

        func finishParagraph() {
            guard currentLeaf != nil else { return }
            out.append(NSAttributedString(string: "\n"))
            style(paragraph: NSRange(location: paragraphStart, length: out.length - paragraphStart), block: currentBlock, in: out)
        }

        for run in parsed.runs {
            let text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            let leaf = components.first
            let leafID = leaf?.identity ?? -1

            var isCell = false
            var rowID: Int?
            for c in components {
                switch c.kind {
                case .tableCell: isCell = true
                case .tableRow, .tableHeaderRow: rowID = c.identity
                default: break
                }
            }

            if leafID != currentLeaf {
                if isCell, let rowID, rowID == currentRow, currentLeaf != nil {
                    // Another cell of the same table row: tab-separated on one line.
                    out.append(NSAttributedString(string: "\t"))
                } else {
                    finishParagraph()
                    currentBlock = block(for: components, marked: &markedItems, lists: &textLists)
                    paragraphStart = out.length
                    if let marker = currentBlock.marker {
                        out.append(NSAttributedString(string: "\t\(marker)\t"))
                    }
                }
                currentLeaf = leafID
                currentRow = isCell ? rowID : nil
            }

            guard !text.isEmpty else { continue }
            let intent = run.inlinePresentationIntent ?? []
            let isBreak = intent.contains(.lineBreak)
            var piece = text
            if case .code = currentBlock.kind {
                // Keep a code block's lines apart without ending the paragraph.
                if piece.hasSuffix("\n") { piece.removeLast() }
                piece = piece.replacingOccurrences(of: "\n", with: "\u{2028}")
            } else {
                if isBreak { piece = "\u{2028}" } else if intent.contains(.softBreak) { piece = " " }
                piece = piece.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            }

            var attributes: [NSAttributedString.Key: Any] = [.font: font(for: currentBlock, intent: intent)]
            if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            if let link = run.link { attributes[.link] = link }
            out.append(NSAttributedString(string: piece, attributes: attributes))
        }
        finishParagraph()
        return out
    }

    private static func block(for components: [PresentationIntent.IntentType], marked: inout Set<Int>,
                              lists cache: inout [Int: NSTextList]) -> Block {
        // `components` runs from the innermost block to the outermost.
        var kind = Block.Kind.paragraph
        var depth = 0
        var ordered: Bool?
        var ordinal: Int?
        var sawItem = false
        var lists: [NSTextList] = []
        func list(_ c: PresentationIntent.IntentType, ordered: Bool) -> NSTextList {
            if let known = cache[c.identity] { return known }
            let made = NSTextList(markerFormat: ordered ? .decimal : .disc, options: 0)
            cache[c.identity] = made
            return made
        }
        for c in components {
            switch c.kind {
            case .header(let level): kind = .heading(level)
            case .codeBlock: kind = .code
            case .blockQuote: if case .paragraph = kind { kind = .quote }
            case .listItem(let n):
                // The first paragraph of each item carries its marker.
                if !sawItem, marked.insert(c.identity).inserted { ordinal = n }
                sawItem = true
            case .orderedList:
                depth += 1
                lists.insert(list(c, ordered: true), at: 0)
                if ordered == nil { ordered = true }
            case .unorderedList:
                depth += 1
                lists.insert(list(c, ordered: false), at: 0)
                if ordered == nil { ordered = false }
            default: break
            }
        }
        let isOrdered = ordered ?? false
        let marker = ordinal.map { isOrdered ? "\($0)." : "\u{2022}" }
        return Block(kind: kind, listDepth: depth, ordered: isOrdered, marker: marker, lists: lists)
    }

    private static func font(for block: Block, intent: InlinePresentationIntent) -> NSFont {
        var size: CGFloat = 12
        var bold = intent.contains(.stronglyEmphasized)
        var italic = intent.contains(.emphasized)
        var family = "Helvetica"
        switch block.kind {
        case .heading(let level):
            size = [24, 20, 16, 14, 13, 12][min(max(level, 1), 6) - 1]
            bold = true
        case .code:
            family = "Courier"
            size = 11
        case .quote:
            italic = true
        case .paragraph:
            break
        }
        if intent.contains(.code) { family = "Courier" }
        var font = NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
        if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    private static func style(paragraph range: NSRange, block: Block, in text: NSMutableAttributedString) {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        if block.listDepth > 0 {
            let markerPosition = CGFloat(block.listDepth) * 18
            style.tabStops = [NSTextTab(textAlignment: .left, location: markerPosition),
                              NSTextTab(textAlignment: .left, location: markerPosition + 18)]
            style.headIndent = markerPosition + 18
            style.firstLineHeadIndent = 0
            style.paragraphSpacing = 2
            style.textLists = block.lists
        }
        switch block.kind {
        case .quote:
            style.headIndent += 18
            style.firstLineHeadIndent += 18
        case .code:
            style.headIndent += 12
            style.firstLineHeadIndent += 12
        default: break
        }
        text.addAttribute(.paragraphStyle, value: style, range: range)
    }

    // MARK: PDF

    private static let margin: CGFloat = 72

    /// Lays the text out on pages of `paper` size with 72 pt margins and writes a PDF to `url`
    /// (which must not exist). The text stays selectable and searchable.
    public static func writePDF(_ attributed: NSAttributedString, to url: URL, paper: CGSize) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw OrbitError.unsupported("Refusing to overwrite existing file \(url.lastPathComponent).")
        }
        let storage = NSTextStorage(attributedString: prepared(attributed))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        let pageText = CGSize(width: paper.width - 2 * margin, height: paper.height - 2 * margin)
        var containers: [NSTextContainer] = []
        var laidOut = 0
        repeat {
            let container = NSTextContainer(size: pageText)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            let range = layout.glyphRange(for: container)
            // A container that takes nothing would loop forever: stop and keep what fit.
            if range.length == 0 {
                if containers.isEmpty { containers.append(container) } else { layout.removeTextContainer(at: containers.count) }
                break
            }
            containers.append(container)
            laidOut = NSMaxRange(range)
        } while laidOut < layout.numberOfGlyphs && containers.count < 10_000

        var mediaBox = CGRect(origin: .zero, size: paper)
        let info = [kCGPDFContextCreator: "Orbit"] as CFDictionary
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info) else {
            throw OrbitError.unsupported("Orbit couldn't create the PDF.")
        }
        let previous = NSGraphicsContext.current
        defer { NSGraphicsContext.current = previous }
        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            // TextKit draws top-down: flip the page so y grows downward from the top-left corner.
            context.translateBy(x: 0, y: paper.height)
            context.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
            let range = layout.glyphRange(for: container)
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: range, at: origin)
            layout.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// Black text unless the document says otherwise (a dynamic color would follow the system appearance),
    /// and blue underlined links.
    private static func prepared(_ source: NSAttributedString) -> NSAttributedString {
        let text = NSMutableAttributedString(attributedString: source)
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttributes(in: whole) { attributes, range, _ in
            if attributes[.foregroundColor] == nil {
                text.addAttribute(.foregroundColor, value: attributes[.link] != nil ? NSColor.systemBlue : NSColor.black, range: range)
            }
            if attributes[.link] != nil, attributes[.underlineStyle] == nil {
                text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: range)
            }
            if attributes[.font] == nil { text.addAttribute(.font, value: bodyFont, range: range) }
        }
        return text
    }
}
