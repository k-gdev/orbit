import Foundation

/// CSV/TSV reading and writing (RFC 4180 quoting).
public enum DelimitedText {
    public static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var fieldStarted = false  // distinguishes an empty trailing line from a row with one empty field
        let chars = Array(text.unicodeScalars)
        let delim = delimiter.unicodeScalars.first ?? ","
        var i = 0

        func endField() { row.append(field); field = ""; fieldStarted = false }
        func endRow() { endField(); rows.append(row); row = [] }

        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.unicodeScalars.append("\""); i += 1 } else { inQuotes = false }
                } else {
                    field.unicodeScalars.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
                fieldStarted = true
            } else if c == delim {
                endField()
                fieldStarted = true
            } else if c == "\r" || c == "\n" {
                if c == "\r", i + 1 < chars.count, chars[i + 1] == "\n" { i += 1 }
                endRow()
            } else {
                field.unicodeScalars.append(c)
                fieldStarted = true
            }
            i += 1
        }
        if fieldStarted || !field.isEmpty || !row.isEmpty { endRow() }
        return rows
    }

    /// Fields containing the delimiter, a quote or a line break are quoted. Every row ends with `\n`.
    public static func write(_ rows: [[String]], delimiter: Character) -> String {
        let d = String(delimiter)
        var out = ""
        for row in rows {
            out += row.map { field in
                let needsQuotes = field.unicodeScalars.contains { $0 == "\"" || $0 == "\n" || $0 == "\r" } || field.contains(delimiter)
                if needsQuotes {
                    return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                }
                return field
            }.joined(separator: d)
            out += "\n"
        }
        return out
    }
}
