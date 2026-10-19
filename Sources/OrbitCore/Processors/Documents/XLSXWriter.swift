import Foundation

/// How spreadsheet writers decide whether a cell is a number.
enum SpreadsheetNumber {
    /// The canonical numeric text for `text`, or nil when it should stay text.
    /// Only plain decimals (`-?digits[.digits]`) whose digits survive a Double round trip are numbers; anything
    /// else (leading "+", exponent forms, "-0", leading-zero codes such as "007", more than 15 significant
    /// digits, "nan"/"inf"/hex) stays text so identifiers are never altered.
    static func canonical(_ text: String) -> String? {
        let body = text.hasPrefix("-") ? String(text.dropFirst()) : text
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard !parts.isEmpty, parts.count <= 2,
              parts.allSatisfy({ $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        let intPart = parts[0], frac = parts.count == 2 ? parts[1] : ""
        if intPart.isEmpty && frac.isEmpty { return nil }
        if parts.count == 2 && frac.isEmpty { return nil }
        if intPart.count > 1, intPart.first == "0" { return nil }
        let sig = (intPart + frac).drop { $0 == "0" }
        let trimmed = frac.isEmpty ? String(sig) : String(sig.reversed().drop { $0 == "0" }.reversed())
        if trimmed.count > 15 { return nil }
        guard let d = Double(text), d.isFinite else { return nil }
        if d == 0 && text.hasPrefix("-") { return nil }
        if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
        return "\(d)"
    }
}

/// Writes a one-sheet .xlsx using only the minimal OOXML parts.
public enum XLSXWriter {
    public static func write(rows: [[String]], sheetName: String, to: URL) async throws {
        let name = sanitizedSheetName(sheetName)
        let ct = """
        \(XMLText.declaration)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
        <Default Extension="xml" ContentType="application/xml"/>\
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>\
        <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>\
        </Types>
        """
        let rels = """
        \(XMLText.declaration)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>\
        </Relationships>
        """
        let workbook = """
        \(XMLText.declaration)<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" \
        xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">\
        <sheets><sheet name="\(XMLText.escape(name))" sheetId="1" r:id="rId1"/></sheets></workbook>
        """
        let wbRels = """
        \(XMLText.declaration)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>\
        </Relationships>
        """
        try await ZipPackager.package(entries: [
            ("[Content_Types].xml", Data(ct.utf8)),
            ("_rels/.rels", Data(rels.utf8)),
            ("xl/workbook.xml", Data(workbook.utf8)),
            ("xl/_rels/workbook.xml.rels", Data(wbRels.utf8)),
            ("xl/worksheets/sheet1.xml", Data(sheetXML(rows).utf8)),
        ], to: to)
    }

    static func sheetXML(_ rows: [[String]]) -> String {
        var xml = XMLText.declaration
        xml += "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\"><sheetData>"
        for (r, row) in rows.enumerated() {
            xml += "<row r=\"\(r + 1)\">"
            for (c, text) in row.enumerated() where !text.isEmpty {
                let ref = "\(columnLetters(c))\(r + 1)"
                if let n = SpreadsheetNumber.canonical(text) {
                    xml += "<c r=\"\(ref)\"><v>\(n)</v></c>"
                } else {
                    xml += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(text))</t></is></c>"
                }
            }
            xml += "</row>"
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    /// 0 -> A, 25 -> Z, 26 -> AA.
    static func columnLetters(_ index: Int) -> String {
        var n = index + 1
        var out = ""
        while n > 0 {
            let rem = (n - 1) % 26
            out = String(UnicodeScalar(UInt8(65 + rem))) + out
            n = (n - 1) / 26
        }
        return out
    }

    /// Excel limits sheet names to 31 characters and forbids `[ ] : * ? / \`.
    static func sanitizedSheetName(_ name: String) -> String {
        let cleaned = String(name.filter { !"[]:*?/\\".contains($0) }.prefix(31))
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Sheet1" : cleaned
    }
}
