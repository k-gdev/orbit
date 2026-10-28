import CoreGraphics
import Foundation

/// One line Vision recognised: its text and bounding box (normalised 0…1, origin at the bottom left).
public struct RecognizedLine: Equatable, Sendable {
    public var text: String
    public var box: CGRect

    public init(text: String, box: CGRect) {
        self.text = text
        self.box = box
    }
}

/// What Grab Text copies and what the HUD says (spec §8.4).
public enum GrabTextResult {
    /// The text to copy (lines trimmed, blank lines dropped, joined with newlines) and the HUD message:
    /// "Copied 1 line", "Copied N lines", or "No text found".
    public static func format(lines: [String]) -> (text: String, hud: String) {
        let clean = lines.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        let hud = switch clean.count {
        case 0: "No text found"
        case 1: "Copied 1 line"
        default: "Copied \(clean.count) lines"
        }
        return (clean.joined(separator: "\n"), hud)
    }

    /// A QR code or barcode in the area wins over its text: its payload is copied instead ("Copied code",
    /// "Copied N codes"; duplicates and blanks dropped). Without one, the text as in `format(lines:)`.
    public static func preferBarcode(payloads: [String], lines: [String]) -> (text: String, hud: String) {
        var seen = Set<String>()
        let codes = payloads.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !codes.isEmpty else { return format(lines: lines) }
        return (codes.joined(separator: "\n"), codes.count == 1 ? "Copied code" : "Copied \(codes.count) codes")
    }

    /// Lines in reading order: rows from top to bottom (fragments whose boxes overlap vertically by at
    /// least half the shorter one share a row), fragments within a row left to right, joined by a space.
    public static func readingOrder(_ lines: [RecognizedLine]) -> [String] {
        let byTop = lines.sorted { $0.box.midY > $1.box.midY }
        var rows: [[RecognizedLine]] = []
        for line in byTop {
            if let last = rows.last?.first, sameRow(last.box, line.box) {
                rows[rows.count - 1].append(line)
            } else {
                rows.append([line])
            }
        }
        return rows.map { row in row.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
    }

    private static func sameRow(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap >= 0.5 * min(a.height, b.height)
    }
}
