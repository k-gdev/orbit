import CoreGraphics
import Foundation

/// Recognises a "shake": the pointer going quickly left and right. Feed it `(point, time)` samples
/// (only `x` matters); `feed` returns true on the sample that completes a shake.
///
/// A reversal is counted when the pointer turns round after a leg of at least `minimumLeg` points: the
/// detector follows the farthest point of the current leg and confirms the turn once the pointer has come
/// back `minimumLeg` points from it, so every leg that ends in a reversal is at least that long and small
/// jitter never counts. A shake is `reversalsNeeded` reversals inside `window` seconds. After one is
/// reported, `lockout` seconds of input are ignored so a long shake opens the shelf once.
public struct ShakeDetector: Sendable {
    /// The shortest horizontal leg, in points, that can end in a reversal.
    public let minimumLeg: Double
    /// How many reversals make a shake.
    public let reversalsNeeded: Int
    /// The reversals must all fall within this many seconds.
    public let window: TimeInterval
    /// After a shake is reported, input is ignored for this many seconds.
    public let lockout: TimeInterval

    /// -1 / 0 / +1: the direction of the current leg (0 until the pointer has first moved `minimumLeg`).
    private var direction = 0
    /// The pointer's starting x while `direction` is 0, else the farthest x reached in `direction`.
    private var anchorX: Double?
    private var reversalTimes: [TimeInterval] = []
    private var lastTime: TimeInterval?
    private var lockedUntil: TimeInterval = -.infinity

    public init(minimumLeg: Double = 40, reversalsNeeded: Int = 3, window: TimeInterval = 0.6, lockout: TimeInterval = 1) {
        self.minimumLeg = minimumLeg
        self.reversalsNeeded = reversalsNeeded
        self.window = window
        self.lockout = lockout
    }

    /// Adds one sample. Returns true when it completes a shake (and then ignores `lockout` seconds).
    public mutating func feed(_ point: CGPoint, at time: TimeInterval) -> Bool {
        // Time going backwards means a different session; start over.
        if let lastTime, time < lastTime { reset() }
        lastTime = time
        guard time >= lockedUntil else { return false }

        let x = Double(point.x)
        guard let anchor = anchorX else {
            anchorX = x
            return false
        }
        if direction == 0 {
            if abs(x - anchor) >= minimumLeg {
                direction = x > anchor ? 1 : -1
                anchorX = x
            }
            return false
        }
        let along = (x - anchor) * Double(direction)
        if along > 0 {
            anchorX = x
            return false
        }
        guard -along >= minimumLeg else { return false }

        // The pointer came back `minimumLeg` from the end of a leg that was at least that long: a reversal.
        direction = -direction
        anchorX = x
        reversalTimes.append(time)
        reversalTimes.removeAll { time - $0 > window }
        guard reversalTimes.count >= reversalsNeeded else { return false }

        reset()
        lockedUntil = time + lockout
        return true
    }

    /// Forgets the gesture in progress (call it when a drag begins or ends). The lockout after a reported
    /// shake is also cleared.
    public mutating func reset() {
        direction = 0
        anchorX = nil
        reversalTimes.removeAll()
        lastTime = nil
        lockedUntil = -.infinity
    }
}
