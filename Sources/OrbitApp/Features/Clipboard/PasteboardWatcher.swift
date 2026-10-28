import AppKit
import OrbitCore

/// Watches the general pasteboard for new copies. macOS has no pasteboard-changed notification, so it
/// polls `changeCount` (an integer read, nothing more) every half second, only between `start` and
/// `stop`. When the count moves it reads the pasteboard through `PasteboardReader` and hands any
/// capture to `onCapture`.
///
/// What was on the pasteboard when `start` ran is not recorded. Orbit's own writes (choosing an entry
/// from the history) are skipped through `ignoreChange(at:)`.
@MainActor
final class PasteboardWatcher {
    static let interval: TimeInterval = 0.5

    private let pasteboard: NSPasteboard
    private var timer: Timer?
    private var lastChangeCount: Int
    private var ignoredChangeCount: Int?
    private var policy: () -> PasteboardPolicy = { PasteboardPolicy(ignoredBundleIDs: [], maxItemBytes: 0) }
    private var onCapture: (ClipboardCapture) -> Void = { _ in }

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    var isRunning: Bool { timer != nil }

    /// Starts polling. Idempotent.
    func start(policy: @escaping () -> PasteboardPolicy, onCapture: @escaping (ClipboardCapture) -> Void) {
        guard timer == nil else { return }
        self.policy = policy
        self.onCapture = onCapture
        lastChangeCount = pasteboard.changeCount
        ignoredChangeCount = nil
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Stops polling and drops the callbacks. Idempotent.
    func stop() {
        timer?.invalidate()
        timer = nil
        onCapture = { _ in }
    }

    /// The pasteboard change with this count is Orbit's own write: don't record it.
    func ignoreChange(at changeCount: Int) {
        ignoredChangeCount = changeCount
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if ignoredChangeCount == count {
            ignoredChangeCount = nil
            return
        }
        switch PasteboardReader.read(pasteboard, policy: policy(), frontmost: AppLookup.frontmost(), now: Date()) {
        case .capture(let capture): onCapture(capture)
        case .skipped(let reason): Log.info("clipboard: skipped a copy (\(reason))")
        case .nothing: break
        }
    }
}
