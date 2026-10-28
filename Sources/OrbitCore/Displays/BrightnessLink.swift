import Foundation

/// "Link brightness": moving one display's pill moves the others with it, proportionally. Values are
/// fractions of each display's own range (0...1), so a ThinkVision boosted to 150 of 150 and an AOC at
/// 100 of 100 both sit at 1.
public enum BrightnessLink {
    /// The new fraction of every display when `id` moves to `newFraction`. Each other display changes by
    /// the same ratio (`other × new / old`); when either side is at zero there is no ratio, so it shifts by
    /// the same amount instead (`other + new − old`), which lets a display parked at 0 come back up.
    /// Everything is clamped to 0...1. Pass the values from when the drag began, not the previous step,
    /// so a drag through zero doesn't lose the others' proportions.
    public static func values<ID: Hashable>(changing id: ID, to newFraction: Double, current: [ID: Double]) -> [ID: Double] {
        let new = clamp(newFraction)
        let old = current[id].map(clamp) ?? new
        var result: [ID: Double] = [:]
        for (other, raw) in current where other != id {
            let value = clamp(raw)
            let moved = old > epsilon && value > epsilon ? value * new / old : value + (new - old)
            result[other] = clamp(moved)
        }
        result[id] = new
        return result
    }

    /// One display taking part in a linked move: its range and its value (in that range's units) when the
    /// drag began.
    public struct Member: Equatable, Sendable {
        public var id: String
        public var range: BrightnessRange
        public var value: Double

        public init(id: String, range: BrightnessRange, value: Double) {
            self.id = id
            self.range = range
            self.value = value
        }
    }

    /// `values(changing:to:current:)` in each display's own units: `value` is in `id`'s range, the result
    /// holds every member's new value in its range, rounded to whole steps.
    public static func values(changing id: String, to value: Double, members: [Member]) -> [String: Double] {
        let unchanged = Dictionary(members.map { ($0.id, $0.value) }, uniquingKeysWith: { first, _ in first })
        guard let moved = members.first(where: { $0.id == id }) else { return unchanged }
        let fractions = Dictionary(members.map { ($0.id, $0.range.fraction(for: $0.value)) }, uniquingKeysWith: { first, _ in first })
        let linked = values(changing: id, to: moved.range.fraction(for: value), current: fractions)
        var result: [String: Double] = [:]
        for member in members where result[member.id] == nil {
            result[member.id] = member.range.value(forFraction: linked[member.id] ?? fractions[member.id] ?? 0)
        }
        return result
    }

    /// Below this a fraction counts as zero (no meaningful ratio).
    private static let epsilon = 1e-6

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
