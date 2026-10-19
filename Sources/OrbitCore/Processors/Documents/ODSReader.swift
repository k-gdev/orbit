import Foundation

/// Reads the first table of an OpenDocument spreadsheet as rows of text.
public enum ODSReader {
    /// Repeat counts above this are clamped (LibreOffice pads sheets with a million empty cells).
    static let repeatCap = 10_000

    public static func read(_ url: URL) async throws -> [[String]] {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let result = try await ProcessRunner.run(unzip, ["-p", url.path, "content.xml"])
        let parser = XMLParser(data: Data(result.stdout.utf8))
        let handler = ContentHandler()
        parser.delegate = handler
        let ok = parser.parse()
        if !ok && !handler.finished {
            throw OrbitError.unsupported("Couldn't read \(url.lastPathComponent).")
        }
        return handler.rows
    }

    private final class ContentHandler: NSObject, XMLParserDelegate {
        var rows: [[String]] = []
        var finished = false

        private var tableDepth = 0
        private var sawTable = false
        private var row: [String] = []
        private var pendingEmptyCells = 0
        private var pendingEmptyRows = 0
        private var rowRepeat = 1
        private var inCell = false
        private var cellRepeat = 1
        private var cellValue: String?
        private var paragraphs: [String] = []
        private var paragraph: String?
        private var annotationDepth = 0

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName qName: String?,
                    attributes a: [String: String] = [:]) {
            if finished { return }
            switch name {
            case "table:table":
                tableDepth += 1
                if tableDepth == 1 { sawTable = true }
            case "table:table-row" where tableDepth == 1:
                row = []
                pendingEmptyCells = 0
                rowRepeat = Self.count(a["table:number-rows-repeated"])
            case "table:table-cell", "table:covered-table-cell":
                guard tableDepth == 1 else { return }
                inCell = true
                cellRepeat = Self.count(a["table:number-columns-repeated"])
                cellValue = a["office:value"] ?? a["office:date-value"] ?? a["office:time-value"]
                    ?? a["office:boolean-value"] ?? a["office:string-value"]
                paragraphs = []
            case "office:annotation":
                annotationDepth += 1
            case "text:p", "text:h":
                if inCell && annotationDepth == 0 { paragraph = "" }
            case "text:s":
                if paragraph != nil { paragraph! += String(repeating: " ", count: Self.count(a["text:c"])) }
            case "text:tab":
                if paragraph != nil { paragraph! += "\t" }
            case "text:line-break":
                if paragraph != nil { paragraph! += "\n" }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if paragraph != nil { paragraph! += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName qName: String?) {
            if finished { return }
            switch name {
            case "text:p", "text:h":
                if let p = paragraph { paragraphs.append(p); paragraph = nil }
            case "office:annotation":
                annotationDepth = max(0, annotationDepth - 1)
            case "table:table-cell", "table:covered-table-cell":
                guard tableDepth == 1, inCell else { return }
                inCell = false
                let text = paragraphs.isEmpty ? (cellValue ?? "") : paragraphs.joined(separator: "\n")
                if text.isEmpty {
                    pendingEmptyCells += cellRepeat
                } else {
                    row.append(contentsOf: Array(repeating: "", count: min(pendingEmptyCells, ODSReader.repeatCap)))
                    pendingEmptyCells = 0
                    row.append(contentsOf: Array(repeating: text, count: cellRepeat))
                }
            case "table:table-row" where tableDepth == 1:
                // Trailing empty cells are dropped (pendingEmptyCells is simply not flushed).
                if row.isEmpty {
                    pendingEmptyRows += rowRepeat
                } else {
                    rows.append(contentsOf: Array(repeating: [], count: min(pendingEmptyRows, ODSReader.repeatCap)))
                    pendingEmptyRows = 0
                    rows.append(contentsOf: Array(repeating: row, count: rowRepeat))
                }
            case "table:table":
                tableDepth -= 1
                if tableDepth == 0 && sawTable {
                    finished = true  // only the first table is read
                    parser.abortParsing()
                }
            default:
                break
            }
        }

        private static func count(_ s: String?) -> Int {
            min(max(Int(s ?? "") ?? 1, 1), ODSReader.repeatCap)
        }
    }
}
