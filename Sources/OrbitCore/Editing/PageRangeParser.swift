import Foundation

/// Parses the page list a person types into the Split editor, such as `1-3, 5`.
public enum PageRangeParser {
    /// Comma-separated items, each `n` or `a-b` (spaces allowed anywhere). Pages count from 1.
    /// Returns nil when the text is empty, an item is malformed, a number is outside `1…pageCount`, or a range has `a > b`.
    public static func parse(_ text: String, pageCount: Int) -> [ClosedRange<Int>]? {
        guard pageCount >= 1 else { return nil }
        var ranges: [ClosedRange<Int>] = []
        for item in text.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count == 1 || bounds.count == 2 else { return nil }
            let numbers = bounds.compactMap { number($0, limit: pageCount) }
            guard numbers.count == bounds.count, let first = numbers.first, let last = numbers.last, first <= last else { return nil }
            ranges.append(first...last)
        }
        return ranges.isEmpty ? nil : ranges
    }

    private static func number(_ text: Substring, limit: Int) -> Int? {
        let digits = text.trimmingCharacters(in: .whitespaces)
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), let value = Int(digits),
              (1...limit).contains(value) else { return nil }
        return value
    }
}
