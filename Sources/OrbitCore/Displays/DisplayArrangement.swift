import CoreGraphics
import Foundation

/// The order and titles of the Displays tab's tiles.
public enum DisplayArrangement {
    public struct Item: Equatable, Sendable {
        /// `NSScreen.localizedName` ("P27u-20 (1)").
        public var name: String
        /// `CGDisplayBounds`: global coordinates, origin top left, y down.
        public var frame: CGRect
        public var isBuiltIn: Bool

        public init(name: String, frame: CGRect, isBuiltIn: Bool = false) {
            self.name = name
            self.frame = frame
            self.isBuiltIn = isBuiltIn
        }
    }

    /// Indices of `items` in tile order: the built-in display first, then left to right by each display's
    /// centre, then top to bottom.
    public static func order(_ items: [Item]) -> [Int] {
        items.indices.sorted { a, b in
            let x = items[a], y = items[b]
            if x.isBuiltIn != y.isBuiltIn { return x.isBuiltIn }
            if x.frame.midX != y.frame.midX { return x.frame.midX < y.frame.midX }
            if x.frame.midY != y.frame.midY { return x.frame.midY < y.frame.midY }
            return a < b
        }
    }

    /// Each item's tile title. macOS's " (1)" / " (2)" suffix is dropped; a name shared by several
    /// displays gets "· Left" / "· Right" (two side by side), "· Top" / "· Bottom" (two stacked), or
    /// "· 1", "· 2", ... in tile order (three or more). An empty name becomes "Display".
    public static func titles(_ items: [Item]) -> [String] {
        let bases = items.map { baseName($0.name) }
        var titles = bases
        let rank = Dictionary(uniqueKeysWithValues: order(items).enumerated().map { ($1, $0) })
        for name in Set(bases) {
            let group = items.indices.filter { bases[$0] == name }.sorted { rank[$0, default: 0] < rank[$1, default: 0] }
            guard group.count > 1 else { continue }
            if group.count == 2 {
                let a = items[group[0]].frame, b = items[group[1]].frame
                let sideBySide = abs(a.midX - b.midX) >= abs(a.midY - b.midY)
                let (first, second) = sideBySide ? (a.midX <= b.midX ? (0, 1) : (1, 0)) : (a.midY <= b.midY ? (0, 1) : (1, 0))
                titles[group[first]] = "\(name) · \(sideBySide ? "Left" : "Top")"
                titles[group[second]] = "\(name) · \(sideBySide ? "Right" : "Bottom")"
            } else {
                for (number, index) in group.enumerated() { titles[index] = "\(name) · \(number + 1)" }
            }
        }
        return titles
    }

    /// The name without macOS's duplicate counter (" (2)").
    static func baseName(_ name: String) -> String {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") {
            let digits = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)]
            if !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), open > trimmed.startIndex,
               trimmed[trimmed.index(before: open)] == " " {
                trimmed = String(trimmed[..<trimmed.index(before: open)]).trimmingCharacters(in: .whitespaces)
            }
        }
        return trimmed.isEmpty ? "Display" : trimmed
    }
}
