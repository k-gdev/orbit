import Foundation

/// Writes a one-sheet OpenDocument spreadsheet.
public enum ODSWriter {
    static let mimetype = "application/vnd.oasis.opendocument.spreadsheet"

    public static func write(rows: [[String]], sheetName: String, to: URL) async throws {
        let name = sheetName.trimmingCharacters(in: .whitespaces).isEmpty ? "Sheet1" : sheetName
        var content = XMLText.declaration
        content += """
        <office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" \
        xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" \
        xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0" office:version="1.2">\
        <office:body><office:spreadsheet><table:table table:name="\(XMLText.escape(name))">
        """
        for row in rows {
            content += "<table:table-row>"
            for text in row {
                if text.isEmpty {
                    content += "<table:table-cell/>"
                } else if let n = SpreadsheetNumber.canonical(text) {
                    content += "<table:table-cell office:value-type=\"float\" office:value=\"\(n)\">\(paragraphs(text))</table:table-cell>"
                } else {
                    content += "<table:table-cell office:value-type=\"string\">\(paragraphs(text))</table:table-cell>"
                }
            }
            content += "</table:table-row>"
        }
        content += "</table:table></office:spreadsheet></office:body></office:document-content>"

        let manifest = """
        \(XMLText.declaration)<manifest:manifest xmlns:manifest="urn:oasis:names:tc:opendocument:xmlns:manifest:1.0" manifest:version="1.2">\
        <manifest:file-entry manifest:full-path="/" manifest:version="1.2" manifest:media-type="\(mimetype)"/>\
        <manifest:file-entry manifest:full-path="content.xml" manifest:media-type="text/xml"/>\
        </manifest:manifest>
        """
        try await ZipPackager.package(entries: [
            ("mimetype", Data(mimetype.utf8)),
            ("content.xml", Data(content.utf8)),
            ("META-INF/manifest.xml", Data(manifest.utf8)),
        ], storedFirst: "mimetype", to: to)
    }

    /// One `text:p` per line. ODF collapses white space, so runs of spaces and tabs are written as `text:s` / `text:tab`.
    static func paragraphs(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return normalized.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            var out = "<text:p>"
            var spaces = 0
            var atStart = true
            func flushSpaces() {
                if spaces > 0 {
                    if atStart { out += "<text:s text:c=\"\(spaces)\"/>" }
                    else {
                        out += " "
                        if spaces > 1 { out += "<text:s text:c=\"\(spaces - 1)\"/>" }
                    }
                    spaces = 0
                }
            }
            for ch in XMLText.escape(String(line)).unicodeScalars {
                if ch == " " { spaces += 1; continue }
                flushSpaces()
                atStart = false
                if ch == "\t" { out += "<text:tab/>" } else { out.unicodeScalars.append(ch) }
            }
            // Trailing spaces still need to survive.
            if spaces > 0 { out += "<text:s text:c=\"\(spaces)\"/>" }
            return out + "</text:p>"
        }.joined()
    }
}
