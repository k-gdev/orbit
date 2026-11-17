import AppKit
import Carbon.HIToolbox
import OrbitCore

/// Global keyboard shortcuts through Carbon's `RegisterEventHotKey`, which needs no permission (unlike a
/// global key monitor). Each shortcut has a string id owned by one feature, e.g. `"clipboard.popup"`;
/// registering an id again replaces its combo. Actions run on the main thread.
///
/// Features register in `start()` and MUST `unregister(id:)` in `stop()`. The Carbon event handler is
/// installed with the first hot key and removed with the last, so no shortcuts cost nothing.
///
/// While a `KeyComboRecorder` is recording, every hot key is suspended so the combo being typed reaches
/// the recorder instead of firing.
@MainActor
final class HotKeyCenter {
    private struct Entry {
        let id: String
        let combo: KeyCombo
        let action: () -> Void
        let number: UInt32
        var ref: EventHotKeyRef?
    }

    private static let signature: OSType = 0x4F52_4254   // 'ORBT'
    private var entries: [String: Entry] = [:]
    private var nextNumber: UInt32 = 1
    private var handler: EventHandlerRef?
    private var suspended = false
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: KeyComboRecorder.didBeginRecording, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(true) }
        })
        observers.append(center.addObserver(forName: KeyComboRecorder.didEndRecording, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.setSuspended(false) }
        })
    }

    /// Registers `combo` under `id` (replacing that id's previous combo). Returns false, and registers
    /// nothing, when another id of Orbit's already uses the combo or macOS refuses it.
    @discardableResult
    func register(_ combo: KeyCombo, id: String, action: @escaping () -> Void) -> Bool {
        if let owner = owner(of: combo), owner != id { return false }
        unregister(id: id)
        var entry = Entry(id: id, combo: combo, action: action, number: nextNumber, ref: nil)
        nextNumber += 1
        installHandlerIfNeeded()
        if !suspended {
            guard let ref = Self.registerCarbon(combo, number: entry.number) else {
                Log.info("hot key \(combo.display) for \(id) was refused")
                removeHandlerIfUnused()
                return false
            }
            entry.ref = ref
        }
        entries[id] = entry
        return true
    }

    /// Removes the shortcut registered under `id` (no-op when there is none).
    func unregister(id: String) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        if let ref = entry.ref { UnregisterEventHotKey(ref) }
        removeHandlerIfUnused()
    }

    /// The id currently registered for `combo`, if any (for "Already used by …" messages).
    func owner(of combo: KeyCombo) -> String? {
        entries.values.first { $0.combo == combo }?.id
    }

    /// The combo registered under `id`, if any.
    func combo(for id: String) -> KeyCombo? { entries[id]?.combo }

    // MARK: Carbon

    private static func registerCarbon(_ combo: KeyCombo, number: UInt32) -> EventHotKeyRef? {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: number)
        let status = RegisterEventHotKey(UInt32(combo.keyCode), carbonModifiers(combo.modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr ? ref : nil
    }

    static func carbonModifiers(_ set: ModifierSet) -> UInt32 {
        var m: UInt32 = 0
        if set.contains(.command) { m |= UInt32(cmdKey) }
        if set.contains(.shift) { m |= UInt32(shiftKey) }
        if set.contains(.option) { m |= UInt32(optionKey) }
        if set.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    private func installHandlerIfNeeded() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
            MainActor.assumeIsolated { center.fire(hotKeyID.id) }
            return noErr
        }
        let status = InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                                         Unmanaged.passUnretained(self).toOpaque(), &handler)
        if status != noErr { Log.error("hot key handler install failed: \(status)"); handler = nil }
    }

    private func removeHandlerIfUnused() {
        guard entries.isEmpty, let handler else { return }
        RemoveEventHandler(handler)
        self.handler = nil
    }

    private func fire(_ number: UInt32) {
        guard !suspended, let entry = entries.values.first(where: { $0.number == number }) else { return }
        entry.action()
    }

    private func setSuspended(_ on: Bool) {
        guard on != suspended else { return }
        suspended = on
        for (id, var entry) in entries {
            if on {
                if let ref = entry.ref { UnregisterEventHotKey(ref) }
                entry.ref = nil
            } else {
                entry.ref = Self.registerCarbon(entry.combo, number: entry.number)
            }
            entries[id] = entry
        }
    }
}
