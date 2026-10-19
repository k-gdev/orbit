import CoreGraphics
import Foundation

/// The result toast's one-line summary.
public enum ResultSummary {
    public static func text(for hint: SummaryHint?, outputCount: Int) -> String {
        switch hint {
        case .sizes(let before, let after)?:
            return sizes(before: before, after: after)
        case .dimensions(let from, let to)?:
            return "\(dimensions(from)) → \(dimensions(to))"
        case .count(let n, let noun)?:
            return "\(n) \(n == 1 ? noun : noun + "s")"
        case .text(let text)?:
            return text
        case nil:
            return outputCount == 1 ? "Saved 1 file" : "Saved \(outputCount) files"
        }
    }

    /// Decimal units, as Finder shows them: "999 bytes", "610 KB", "2.4 MB", "1.25 GB".
    /// Always uses "." so the copy is the same in every locale.
    public static func bytes(_ count: Int64) -> String {
        let n = max(count, 0)
        if n < 1000 { return n == 1 ? "1 byte" : "\(n) bytes" }
        let units: [(name: String, decimals: Int)] = [("KB", 0), ("MB", 1), ("GB", 2), ("TB", 2)]
        var value = Double(n) / 1000
        var index = 0
        while true {
            let unit = units[index]
            let scale = pow(10, Double(unit.decimals))
            let rounded = (value * scale).rounded() / scale
            // Rounding up to 1000 moves to the next unit ("999.99 KB" reads as "1 MB").
            if rounded < 1000 || index == units.count - 1 {
                return "\(trimmed(rounded, decimals: unit.decimals)) \(unit.name)"
            }
            value /= 1000
            index += 1
        }
    }

    private static func sizes(before: Int64, after: Int64) -> String {
        let head = "\(bytes(before)) → \(bytes(after))"
        guard before > 0 else { return head }
        let change = Double(after) - Double(before)
        var percent = Int((abs(change) / Double(before) * 100).rounded())
        if percent == 0 { return "\(head) · same size" }
        if change < 0 {
            if after > 0 { percent = min(percent, 99) } // never claim "100% smaller" for a non-empty file
            return "\(head) · \(percent)% smaller"
        }
        return "\(head) · \(percent)% larger"
    }

    private static func dimensions(_ size: CGSize) -> String {
        "\(pixels(size.width))×\(pixels(size.height))"
    }

    private static func pixels(_ v: CGFloat) -> Int {
        v.isFinite && abs(v) < 1e15 ? Int(v.rounded()) : 0
    }

    private static func trimmed(_ value: Double, decimals: Int) -> String {
        var s = String(format: "%.\(decimals)f", value)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }
}
