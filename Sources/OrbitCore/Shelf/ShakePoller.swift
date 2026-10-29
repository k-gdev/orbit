import CoreGraphics
import Foundation

/// The decisions behind the shelf's shake watcher, with the clock and the mouse left to the caller. The watcher
/// does not rely on drag events reaching a global monitor while another app runs a drag session (the wheel's
/// `InputSampler` polls for the same reason): a global mouse-down starts a timer, and the timer calls `tick`
/// with what it reads (`NSEvent.pressedMouseButtons`, `NSEvent.mouseLocation`, the drag pasteboard) until `tick`
/// says `.stop` (the button came up).
///
/// While the button is down but no file drag has begun it answers `.waiting`: poll slowly
/// (`waitingInterval`), looking at the drag pasteboard only when its change count has moved. Once the pasteboard
/// changed after the press and holds file URLs (`FileDragGate`) it answers `.tracking`: poll fast
/// (`trackingInterval`) and every sample goes to the `ShakeDetector`, whose shake comes back as `.shake`.
public struct ShakePoller: Sendable {
    public enum Outcome: Equatable, Sendable {
        /// The button is up: stop the timer.
        case stop
        /// The button is down but nothing is being dragged that carries files (yet): keep the slow timer.
        case waiting
        /// A file drag is under way: use the fast timer.
        case tracking
        /// The pointer was shaken during a file drag, here.
        case shake(CGPoint)
    }

    /// Seconds between looks while waiting for a file drag to begin (about 20 a second).
    public static let waitingInterval: TimeInterval = 0.05
    /// Seconds between samples while a file drag is under way (60 a second).
    public static let trackingInterval: TimeInterval = 1.0 / 60

    private var gate = FileDragGate()
    private var detector: ShakeDetector
    private var confirmed = false
    private var inspectedChangeCount: Int?
    private var inspectedHasFiles = false

    public init(detector: ShakeDetector = ShakeDetector()) {
        self.detector = detector
    }

    /// The left button went down with the drag pasteboard at `changeCount`. Starts a fresh press.
    public mutating func buttonDown(changeCount: Int) {
        reset()
        gate.buttonDown(changeCount: changeCount)
    }

    /// One reading. `hasFiles` is called (at most once per pasteboard change) only when the pasteboard has
    /// changed since the press and no file drag has been recognised yet.
    public mutating func tick(buttonDown: Bool, changeCount: Int, hasFiles: () -> Bool,
                              point: CGPoint, time: TimeInterval) -> Outcome {
        guard buttonDown else {
            reset()
            return .stop
        }
        if !confirmed {
            // Same pasteboard as at the press: nothing new has been dragged, so don't even look at its types.
            if inspectedChangeCount != changeCount {
                inspectedChangeCount = changeCount
                inspectedHasFiles = gate.isFileDrag(changeCount: changeCount, hasFiles: true) ? hasFiles() : false
            }
            guard inspectedHasFiles, gate.isFileDrag(changeCount: changeCount, hasFiles: true) else { return .waiting }
            confirmed = true
            detector.reset()
        }
        return detector.feed(point, at: time) ? .shake(point) : .tracking
    }

    /// Forgets the press in progress.
    public mutating func reset() {
        gate.buttonUp()
        detector.reset()
        confirmed = false
        inspectedChangeCount = nil
        inspectedHasFiles = false
    }
}
