import Foundation

/// A resolution change waiting for the user: applied for this session only, kept permanently on "Keep",
/// reverted to `previous` on "Revert" or when `deadline` passes (the display may be unreadable).
public struct ResolutionConfirmation: Equatable, Sendable {
    /// How long the user has to keep a new resolution.
    public static let duration: TimeInterval = 15

    public var displayID: UInt32
    public var displayTitle: String
    public var previous: RawDisplayMode
    public var proposed: RawDisplayMode
    /// "2560 × 1440 HiDPI · 60 Hz".
    public var proposedLabel: String
    public var deadline: Date

    public init(displayID: UInt32, displayTitle: String, previous: RawDisplayMode, proposed: RawDisplayMode,
                proposedLabel: String, startedAt: Date, duration: TimeInterval = ResolutionConfirmation.duration) {
        self.displayID = displayID
        self.displayTitle = displayTitle
        self.previous = previous
        self.proposed = proposed
        self.proposedLabel = proposedLabel
        self.deadline = startedAt.addingTimeInterval(duration)
    }

    /// Whole seconds left, rounded up, never negative.
    public func secondsLeft(at now: Date) -> Int {
        max(Int(deadline.timeIntervalSince(now).rounded(.up)), 0)
    }

    /// Whether it should revert now.
    public func isExpired(at now: Date) -> Bool { now >= deadline }

    /// "Reverting in 12 s", or "Reverting…" at the end.
    public func countdown(at now: Date) -> String {
        let left = secondsLeft(at: now)
        return left > 0 ? "Reverting in \(left) s" : "Reverting…"
    }
}
