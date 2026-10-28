import AppKit
import OrbitCore

/// Opens the shelf when the cursor is shaken during a file drag. It is independent of the wheel's drag
/// watcher: its only moving part is one global mouse monitor (mouse events need no permission), installed
/// by `start()` and removed by `stop()`, so while the feature or the setting is off it costs nothing.
///
/// The monitor sees button presses and drags in other apps. It counts a drag only when the drag pasteboard
/// changed after the button went down and holds file URLs (`FileDragGate`), so shaking the mouse while
/// selecting text or moving a window does nothing. Samples then go to `ShakeDetector`.
@MainActor
final class ShakeWatcher {
    /// Called with the pointer position (screen coordinates) when a shake is recognised.
    var onShake: (CGPoint) -> Void = { _ in }

    private var monitor: Any?
    private var detector = ShakeDetector()
    private var gate = FileDragGate()
    private let dragPasteboard = NSPasteboard(name: .drag)
    /// The change count `hasFiles` was read for, so the pasteboard is inspected once per drag, not per event.
    private var inspectedChangeCount = -1
    private var hasFiles = false
    /// Once a file drag is recognised, later events of the same press skip the pasteboard altogether.
    private var isFileDragConfirmed = false
    private var lastPasteboardCheck: TimeInterval = -.infinity
    /// Until a file drag is confirmed the pasteboard is looked at no more often than this (seconds).
    private static let pasteboardCheckInterval: TimeInterval = 0.05

    var isRunning: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        detector.reset()
        gate = FileDragGate()
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        if monitor == nil { Log.error("shelf: global mouse monitor unavailable; shake to open won't work") }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        detector.reset()
        gate = FileDragGate()
        inspectedChangeCount = -1
        hasFiles = false
        isFileDragConfirmed = false
        lastPasteboardCheck = -.infinity
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            gate.buttonDown(changeCount: dragPasteboard.changeCount)
            detector.reset()
            isFileDragConfirmed = false
            lastPasteboardCheck = -.infinity
        case .leftMouseUp:
            gate.buttonUp()
            detector.reset()
            isFileDragConfirmed = false
        case .leftMouseDragged:
            if !isFileDragConfirmed {
                // Drags in other apps (selecting text, moving a window) arrive here too, at 60 Hz or more:
                // look at the pasteboard a few times a second until it says this is a drag of files.
                guard event.timestamp - lastPasteboardCheck >= Self.pasteboardCheckInterval else { return }
                lastPasteboardCheck = event.timestamp
                let changeCount = dragPasteboard.changeCount
                if changeCount != inspectedChangeCount {
                    inspectedChangeCount = changeCount
                    hasFiles = dragPasteboard.types?.contains(.fileURL) ?? false
                }
                guard gate.isFileDrag(changeCount: changeCount, hasFiles: hasFiles) else { return }
                isFileDragConfirmed = true
            }
            let point = NSEvent.mouseLocation
            if detector.feed(point, at: event.timestamp) { onShake(point) }
        default:
            break
        }
    }
}
