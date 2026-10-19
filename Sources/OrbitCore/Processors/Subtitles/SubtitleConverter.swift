import Foundation

/// One subtitle: when it shows (seconds from the start) and what it says. `text` may hold several
/// lines separated by `\n` and the markup tags (`<i>`) the file carried.
public struct Cue: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum SubtitleFormat: Sendable {
    case srt, vtt
}

/// SRT and WebVTT reading and writing. Pure text; no files.
public enum SubtitleConverter {
    /// Reads cues from `text`. Blocks without a timing line are skipped; for WebVTT so are `NOTE`,
    /// `STYLE` and `REGION` blocks, and the cue settings after the end time are dropped.
    public static func parse(_ text: String, format: SubtitleFormat) -> [Cue] {
        var source = text
        if source.hasPrefix("\u{FEFF}") { source.removeFirst() }
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")

        var blocks: [[String]] = []
        var block: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !block.isEmpty { blocks.append(block); block = [] }
            } else {
                block.append(line)
            }
        }
        if !block.isEmpty { blocks.append(block) }

        var cues: [Cue] = []
        for block in blocks {
            if format == .vtt, isNonCueBlock(block[0]) { continue }
            guard let timing = block.firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = times(in: block[timing]) else { continue }
            var body = Array(block[(timing + 1)...])
            while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty { body.removeLast() }
            cues.append(Cue(start: start, end: end, text: body.joined(separator: "\n")))
        }
        return cues
    }

    /// Cues numbered from 1, timestamps `HH:MM:SS,mmm`, a blank line between cues.
    public static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, separator: ",")) --> \(timestamp(cue.end, separator: ","))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// `WEBVTT`, a blank line, then the cues with timestamps `HH:MM:SS.mmm`.
    public static func vtt(_ cues: [Cue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, separator: ".")) --> \(timestamp(cue.end, separator: "."))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    /// One line per cue with markup tags (`<i>`, `{\an8}`) removed and line breaks turned into spaces.
    /// Cues with no text left are omitted.
    public static func plainText(_ cues: [Cue]) -> String {
        var out = ""
        for cue in cues {
            var line = cue.text
            for pattern in ["<[^>]*>", "\\{\\\\[^}]*\\}"] {
                line = line.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
            }
            for (entity, character) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] {
                line = line.replacingOccurrences(of: entity, with: character)
            }
            line = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            if !line.isEmpty { out += line + "\n" }
        }
        return out
    }

    // MARK: Helpers

    private static func isNonCueBlock(_ firstLine: String) -> Bool {
        for keyword in ["NOTE", "STYLE", "REGION"] {
            guard firstLine.hasPrefix(keyword) else { continue }
            let rest = firstLine.dropFirst(keyword.count)
            if rest.isEmpty || rest.first == " " || rest.first == "\t" { return true }
        }
        return false
    }

    /// The start and end of `start --> end [settings]`.
    private static func times(in line: String) -> (Double, Double)? {
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2,
              let start = seconds(parts[0].trimmingCharacters(in: .whitespaces)),
              let endToken = parts[1].split(whereSeparator: { $0 == " " || $0 == "\t" }).first,
              let end = seconds(String(endToken)) else { return nil }
        return (start, end)
    }

    /// `HH:MM:SS,mmm`, `HH:MM:SS.mmm` or `MM:SS.mmm`.
    private static func seconds(_ stamp: String) -> Double? {
        let fields = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2 || fields.count == 3 else { return nil }
        var total = 0.0
        for field in fields.dropLast() {
            guard !field.isEmpty, field.allSatisfy(\.isASCII), let n = Int(field) else { return nil }
            total = total * 60 + Double(n)
        }
        guard let last = fields.last, !last.isEmpty,
              last.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
              last.filter({ $0 == "." }).count <= 1, let s = Double(last) else { return nil }
        return total * 60 + s
    }

    private static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = max(0, Int((seconds * 1000).rounded()))
        return "\(pad(ms / 3_600_000, 2)):\(pad(ms / 60_000 % 60, 2)):\(pad(ms / 1000 % 60, 2))\(separator)\(pad(ms % 1000, 3))"
    }

    private static func pad(_ n: Int, _ width: Int) -> String {
        let digits = String(n)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
