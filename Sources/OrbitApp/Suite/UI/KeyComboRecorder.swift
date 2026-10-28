import AppKit
import OrbitCore
import SwiftUI

/// A button showing a shortcut ("⌃⌥M"); click it, press the new combo, and it is written to `combo`.
/// Esc cancels. Only combos with ⌃, ⌥ or ⌘ (or a bare F-key) are accepted (`KeyCombo.isUsableAsHotKey`).
/// `conflict` is a message the caller computed (for example "Already used by Clipboard") shown in red
/// beside the button.
///
/// Recording uses a local key monitor (no permission). While it records, `HotKeyCenter` suspends every
/// hot key, so pressing the current combo records it instead of firing it. Re-register your hot key when
/// the binding changes.
struct KeyComboRecorder: View {
    @Binding var combo: KeyCombo
    let conflict: String?

    /// Posted when recording starts and ends; `HotKeyCenter` suspends hot keys in between.
    static let didBeginRecording = Notification.Name("OrbitKeyComboRecorderDidBegin")
    static let didEndRecording = Notification.Name("OrbitKeyComboRecorderDidEnd")

    @State private var recording = false
    @State private var live: ModifierSet = []
    @State private var hint: String?
    @State private var monitor: Any?

    init(combo: Binding<KeyCombo>, conflict: String? = nil) {
        _combo = combo
        self.conflict = conflict
    }

    var body: some View {
        HStack(spacing: 8) {
            if let message = hint ?? conflict {
                Text(message).font(.caption).foregroundStyle(hint == nil ? Color.red : Color.secondary)
                    .lineLimit(1)
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? (live.isEmpty ? "Press shortcut…" : live.symbols + "…") : combo.display)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .frame(minWidth: 96)
            }
            .help(recording ? "Press the new shortcut, or Esc to cancel" : "Click to record a new shortcut")
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        live = []
        hint = nil
        recording = true
        NotificationCenter.default.post(name: Self.didBeginRecording, object: nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            let modifiers = InputSampler.modifierSet(from: event.modifierFlags)
            if event.type == .flagsChanged {
                live = modifiers
                return event
            }
            if event.keyCode == 53 && modifiers.isEmpty {   // Esc
                stop()
                return nil
            }
            let candidate = KeyCombo(keyCode: event.keyCode, modifiers: modifiers)
            guard candidate.isUsableAsHotKey else {
                hint = KeyCombo.keyName(for: event.keyCode) == nil ? "That key can't be a shortcut"
                                                                    : "Add ⌃, ⌥ or ⌘"
                return nil
            }
            combo = candidate
            stop()
            return nil
        }
    }

    private func stop() {
        guard recording || monitor != nil else { return }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        live = []
        NotificationCenter.default.post(name: Self.didEndRecording, object: nil)
    }
}
