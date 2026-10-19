import AppKit
import Foundation

/// Converts rich text to Markdown: headings from font size, bold, italic, links and bulleted lists.
public enum MarkdownWriter {
    private struct Style: Equatable {
        var bold = false
        var italic = false
        var link: String?
    }

    private struct Block {
        var text: String
        var isListItem: Bool
    }

    public static func markdown(from attributed: NSAttributedString) -> String {
        let whole = attributed.string as NSString
        guard whole.length > 0 else { return "" }
        let body = bodySize(of: attributed)

        var blocks: [Block] = []
        whole.enumerateSubstrings(in: NSRange(location: 0, length: whole.length), options: .byParagraphs) { _, range, _, _ in
            if let block = block(for: range, in: attributed, bodySize: body) { blocks.append(block) }
        }

        var out = ""
        for (i, block) in blocks.enumerated() {
            if i > 0 { out += (block.isListItem && blocks[i - 1].isListItem) ? "\n" : "\n\n" }
            out += block.text
        }
        return out.isEmpty ? "" : out + "\n"
    }

    /// The most common font size, weighted by characters (ties go to the smaller size).
    private static func bodySize(of s: NSAttributedString) -> CGFloat {
        var weight: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { value, range, _ in
            guard let font = value as? NSFont else { return }
            weight[(font.pointSize * 2).rounded() / 2, default: 0] += range.length
        }
        return weight.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key ?? 12
    }

    private static let listMarker = try! NSRegularExpression(
        pattern: "^[ \\t]*(?:[•◦▪▫‣⁃●○■□\\-\\*]|\\d+[.)]|[A-Za-z][.)])\\t[ \\t]*")

    private static func block(for paragraphRange: NSRange, in s: NSAttributedString, bodySize: CGFloat) -> Block? {
        var range = paragraphRange
        let style = s.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        let listDepth = style?.textLists.count ?? 0
        let isList = listDepth > 0

        if isList, let m = listMarker.firstMatch(in: s.string, range: range) {
            range = NSRange(location: range.location + m.range.length, length: range.length - m.range.length)
        }

        var maxSize: CGFloat = 0
        var runs: [(text: String, style: Style)] = []
        s.enumerateAttributes(in: range) { attrs, r, _ in
            let font = attrs[.font] as? NSFont
            if let font, !isBlank(s.attributedSubstring(from: r).string) { maxSize = max(maxSize, font.pointSize) }
            var st = Style()
            if let traits = font?.fontDescriptor.symbolicTraits {
                st.bold = traits.contains(.bold)
                st.italic = traits.contains(.italic)
            }
            if let link = attrs[.link] {
                if let url = link as? URL { st.link = url.absoluteString } else if let str = link as? String { st.link = str }
            }
            let text = s.attributedSubstring(from: r).string
            if let last = runs.last, last.style == st { runs[runs.count - 1].text += text } else { runs.append((text, st)) }
        }

        var heading = ""
        if maxSize >= bodySize * 1.6 { heading = "# " } else if maxSize >= bodySize * 1.25 { heading = "## " }

        var line = ""
        for run in runs { line += render(run.text, run.style, plainEmphasis: !heading.isEmpty) }
        line = line.trimmingCharacters(in: .whitespaces)
        guard !isBlank(line) else { return nil }

        if isList {
            return Block(text: String(repeating: "  ", count: listDepth - 1) + "- " + line, isListItem: true)
        }
        return Block(text: heading + line, isListItem: false)
    }

    private static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) || $0 == "\u{FFFC}" }
    }

    /// One run of same-styled text. White space at the edges stays outside the markers.
    private static func render(_ raw: String, _ style: Style, plainEmphasis: Bool) -> String {
        let cleaned = raw.replacingOccurrences(of: "\u{FFFC}", with: "")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\u{2028}", with: "\n")
            .replacingOccurrences(of: "\u{000B}", with: "\n")
        let core = cleaned.trimmingCharacters(in: .whitespaces)
        guard !core.isEmpty else { return cleaned.isEmpty ? "" : " " }
        let lead = cleaned.prefix { $0 == " " || $0 == "\t" }
        let trail = String(cleaned.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())

        var text = escape(core).replacingOccurrences(of: "\n", with: "  \n")
        if let link = style.link {
            text = "[" + text + "](" + link.replacingOccurrences(of: ")", with: "%29").replacingOccurrences(of: " ", with: "%20") + ")"
        }
        if !plainEmphasis {
            if style.bold && style.italic { text = "***" + text + "***" }
            else if style.bold { text = "**" + text + "**" }
            else if style.italic { text = "*" + text + "*" }
        }
        return String(lead) + text + trail
    }

    private static func escape(_ s: String) -> String {
        var out = ""
        for ch in s {
            if "\\*`[]".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}
