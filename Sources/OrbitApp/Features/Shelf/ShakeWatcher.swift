import AppKit
import OrbitCore

/// Opens the shelf when the cursor is shaken during a file drag. It is independent of the wheel's drag
/// watcher, and it does not depend on drag events reaching a global monitor while another app runs its drag
/// session (nobody has verified that on macOS 26); like the wheel's `InputSampler` it polls instead:
///
/// - `start()` installs one global monitor for left-button presses (mouse events need no permission) and
///   nothing else; `stop()` removes it and any timer. While the feature or the setting is off nothing exists.
/// - A press starts a timer. It reads `NSEvent.pressedMouseButtons`, the pointer and the drag pasteboard
///   and hands them to `ShakePoller`, which decides: keep waiting (about 20 looks a second, the pasteboard's
///   types are read only when its change count moves), a file drag is under way (60 samples a second into
///   `ShakeDetector`), a shake was made, or the button is up and the timer stops.
///
/// A click costs one or two timer ticks; a drag of anything but files costs about 20 cheap ticks a second
/// until the button is released.
@MainActor
final class ShakeWatcher {
    /// What the watcher reads from the system. Replaceable so the glue can be checked without a real drag.
    struct Inputs {
        var buttonDown: () -> Bool
        var changeCount: () -> Int
        var holdsFiles: () -> Bool
        var location: () -> CGPoint
        var now: () -> TimeInterval

        /// The real mouse, drag pasteboard and clock.
        static var live: Inputs {
            let pasteboard = NSPasteboard(name: .drag)
            return Inputs(buttonDown: { NSEvent.pressedMouseButtons & 1 != 0 },
                          changeCount: { pasteboard.changeCount },
                          holdsFiles: { pasteboard.types?.contains(.fileURL) ?? false },
                          location: { NSEvent.mouseLocation },
                          now: { ProcessInfo.processInfo.systemUptime })
        }
    }

    /// Called with the pointer position (screen coordinates) when a shake is recognised.
    var onShake: (CGPoint) -> Void = { _ in }

    private let inputs: Inputs
    private var monitor: Any?
    private var poller = ShakePoller()
    private var timer: Timer?
    /// The timer runs at the fast rate because a file drag is under way.
    private(set) var isTracking = false
    private var lastChangeCount = 0

    init(inputs: Inputs = .live) {
        self.inputs = inputs
    }

    /// The press monitor is installed.
    var isRunning: Bool { monitor != nil }
    /// A timer is running (a button is down and the watcher is polling).
    var isPolling: Bool { timer != nil }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressBegan() }
        }
        if monitor == nil { Log.error("shelf: global mouse monitor unavailable; shake to open won't work") }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        stopTimer()
        poller.reset()
    }

    /// A left-button press anywhere: begin polling until the button is released.
    func pressBegan() {
        lastChangeCount = inputs.changeCount()
        poller.buttonDown(changeCount: lastChangeCount)
        isTracking = false
        startTimer(tracking: false)
        poll()
    }

    /// One timer tick.
    func poll() {
        // Once a file drag is confirmed the pasteboard no longer matters, so don't ask it 60 times a second.
        if !isTracking { lastChangeCount = inputs.changeCount() }
        let outcome = poller.tick(buttonDown: inputs.buttonDown(), changeCount: lastChangeCount, hasFiles: inputs.holdsFiles,
                                  point: inputs.location(), time: inputs.now())
        switch outcome {
        case .stop:
            stopTimer()
        case .waiting:
            break
        case .tracking:
            if !isTracking { startTimer(tracking: true) }
        case .shake(let point):
            if !isTracking { startTimer(tracking: true) }
            onShake(point)
        }
    }

    // MARK: Timer

    private func startTimer(tracking: Bool) {
        timer?.invalidate()
        isTracking = tracking
        let interval = tracking ? ShakePoller.trackingInterval : ShakePoller.waitingInterval
        let newTimer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        newTimer.tolerance = tracking ? 0 : 0.01
        // Common modes, so it also runs while a menu or a drag session is tracking events.
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        isTracking = false
    }
}
