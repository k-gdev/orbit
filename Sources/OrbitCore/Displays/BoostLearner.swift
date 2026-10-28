import Foundation

/// Decides when a monitor's boost range is learned for good: a DDC reply whose current value is above its
/// reported maximum (a ThinkVision's "150 of 100") must be seen in two validated readings in a row, so one
/// odd reply can't stretch the pill forever. The current session still shows the range from the latest
/// reading (`BrightnessRange(reportedCurrent:)`); only remembering it waits for the second one.
public struct BoostLearner: Equatable, Sendable {
    private var pending: [String: Int] = [:]

    public init() {}

    /// Feeds one validated reading for `key`. Returns the maximum to remember (the lower of the two
    /// readings) on the second reading in a row above the reported maximum; otherwise nil.
    public mutating func observe(_ reading: VCPValue, for key: String) -> Int? {
        guard reading.current > reading.maximum else {
            pending[key] = nil
            return nil
        }
        defer { pending[key] = reading.current }
        return pending[key].map { min($0, reading.current) }
    }

    /// Drops what was seen for `key` (Settings → Reset learned range).
    public mutating func forget(_ key: String) {
        pending[key] = nil
    }
}
