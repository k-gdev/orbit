import AppKit
import OrbitCore

/// Samples the global mouse button, modifier keys, pointer and drag pasteboard by
/// polling, which needs no Accessibility or Input Monitoring permission (spec §8).
///
/// Idle cost stays near zero: a 4 Hz timer is the only work while the button is up.
/// A mouse-down (seen by a global or local monitor, or by the idle timer as a backstop)
/// starts a 60 Hz sampler, which stops 0.3 s after the button is released while the
/// wheel is closed.
@MainActor
final class InputSampler {
    static let fastInterval: TimeInterval = 1.0 / 60
    static let idleInterval: TimeInterval = 0.25
    /// How long the fast sampler keeps running after the button is released.
    static let releaseTail: TimeInterval = 0.3

    /// While this returns true (the wheel is open) the fast sampler keeps running
    /// after the button is released.
    var keepsSampling: () -> Bool = { false }

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var onSample: ((InputSample) -> Void)?
    private var monitors: [Any] = []
    private var idleTimer: Timer?
    private var fastTimer: Timer?
    private var releasedAt: TimeInterval?

    func start(onSample: @escaping (InputSample) -> Void) {
        stop()
        self.onSample = onSample
        // Mouse events need no permission to monitor; key events would.
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginFastSampling() }
        }
        let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.beginFastSampling() }
            return event
        }
        if global == nil { Log.error("trigger: global mouse-down monitor unavailable; relying on the 4 Hz backstop") }
        monitors = [global, local].compactMap { $0 }
        idleTimer = Self.scheduledTimer(interval: Self.idleInterval, tolerance: 0.05) { [weak self] in
            self?.idleTick()
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        idleTimer?.invalidate()
        idleTimer = nil
        stopFastSampling()
        onSample = nil
    }

    static func modifierSet(from flags: NSEvent.ModifierFlags) -> ModifierSet {
        var set: ModifierSet = []
        if flags.contains(.shift) { set.insert(.shift) }
        if flags.contains(.control) { set.insert(.control) }
        if flags.contains(.option) { set.insert(.option) }
        if flags.contains(.command) { set.insert(.command) }
        return set
    }

    // MARK: Sampling

    /// Backstop for a mouse-down the monitors missed; otherwise one cheap idle sample.
    private func idleTick() {
        guard fastTimer == nil else { return }
        if NSEvent.pressedMouseButtons & 1 != 0 {
            beginFastSampling()
        } else {
            onSample?(takeSample())
        }
    }

    private func beginFastSampling() {
        releasedAt = nil
        guard fastTimer == nil, onSample != nil else { return }
        fastTimer = Self.scheduledTimer(interval: Self.fastInterval, tolerance: 0) { [weak self] in
            self?.fastTick()
        }
        fastTick()
    }

    private func stopFastSampling() {
        fastTimer?.invalidate()
        fastTimer = nil
        releasedAt = nil
    }

    private func fastTick() {
        let sample = takeSample()
        onSample?(sample)
        guard fastTimer != nil else { return } // stopped from inside onSample
        if sample.buttonDown || keepsSampling() {
            releasedAt = nil
        } else if let releasedAt {
            if sample.time - releasedAt >= Self.releaseTail { stopFastSampling() }
        } else {
            releasedAt = sample.time
        }
    }

    private func takeSample() -> InputSample {
        InputSample(time: ProcessInfo.processInfo.systemUptime,
                    buttonDown: NSEvent.pressedMouseButtons & 1 != 0,
                    modifiers: Self.modifierSet(from: NSEvent.modifierFlags),
                    location: NSEvent.mouseLocation,
                    dragChangeCount: dragPasteboard.changeCount,
                    dragHasFiles: dragPasteboard.types?.contains(.fileURL) ?? false)
    }

    /// A main-run-loop timer in the common modes, so it also fires while a menu or
    /// modal panel is tracking events.
    private static func scheduledTimer(interval: TimeInterval, tolerance: TimeInterval,
                                       action: @escaping @MainActor () -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { action() }
        }
        timer.tolerance = tolerance
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}
