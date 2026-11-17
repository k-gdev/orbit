import AppKit
import OrbitCore
import SwiftUI

/// Tracks a modifier chord: the largest set pressed before every key is released.
struct ModifierChordTracker {
    private(set) var chord: ModifierSet = []

    /// Feed each flags change. Returns the finished chord once all modifiers are released.
    mutating func update(_ current: ModifierSet) -> ModifierSet? {
        if current.isEmpty {
            defer { chord = [] }
            return chord.isEmpty ? nil : chord
        }
        if current.rawValue.nonzeroBitCount >= chord.rawValue.nonzeroBitCount { chord = current }
        return nil
    }
}

enum TriggerValidation {
    /// Why `combo` can't be added to `kind`, or nil when it's fine (ruling R27).
    static func rejection(of combo: ModifierSet, for kind: WheelKind, in bindings: TriggerBindings) -> String? {
        guard !combo.isEmpty else { return "Press at least one modifier" }
        for other in WheelKind.allCases where bindings.combos(for: other).contains(combo) {
            return "Already used by \(other.title)"
        }
        return nil
    }
}

extension TriggerBindings {
    func combos(for kind: WheelKind) -> [ModifierSet] {
        switch kind {
        case .convert: convert
        case .tools: tools
        case .actions: actions
        }
    }

    mutating func set(_ combos: [ModifierSet], for kind: WheelKind) {
        switch kind {
        case .convert: convert = combos
        case .tools: tools = combos
        case .actions: actions = combos
        }
    }
}

extension WheelKind {
    var title: String {
        switch self {
        case .convert: "Convert"
        case .tools: "Tools"
        case .actions: "Actions"
        }
    }
}

/// A button that records a modifier combo. While recording, a *local* `.flagsChanged`
/// monitor (no global monitor, so no permission) watches the keyboard; Esc cancels.
struct TriggerRecorder: View {
    let onRecord: (ModifierSet) -> Void
    @State private var recording = false
    @State private var live: ModifierSet = []
    @State private var tracker = ModifierChordTracker()
    @State private var monitor: Any?

    var body: some View {
        Button {
            recording ? stop() : start()
        } label: {
            Text(recording ? (live.isEmpty ? "Press modifiers…" : live.symbols) : "Record…")
                .frame(minWidth: 96)
        }
        .onDisappear { stop() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stop() }
    }

    private func start() {
        tracker = ModifierChordTracker()
        live = []
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                if event.keyCode == 53 { stop(); return nil }   // Esc
                return event
            }
            let current = InputSampler.modifierSet(from: event.modifierFlags)
            if !current.isEmpty { live = current }
            if let chord = tracker.update(current) {
                stop()
                onRecord(chord)
            }
            return event
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        live = []
    }
}
