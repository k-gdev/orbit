import CoreGraphics
import OrbitCore

/// Software dimming: scales a display's gamma tables (`CGSetDisplayTransferByTable`) for monitors that don't
/// answer DDC. It only ever touches displays Orbit dims, and never resets other displays' or other apps'
/// tables (no `CGDisplayRestoreColorSyncSettings`):
///
/// - Each display's original table is captured once per run (per display identity), before Orbit first dims
///   it. A table that already looks dimmed (`GammaRamp.trustedOriginal`) is lifted back to full instead of
///   being trusted, so dimming never compounds.
/// - Restoring a display (back to 100, the fallback turned off, `stop()`, quit) re-applies its original.
/// - After a display change or wake, the dimmed displays get their scaled originals again (macOS may have
///   reset them).
///
/// macOS also drops a process's gamma changes when it exits, so a crash can't leave a screen dimmed.
@MainActor
final class GammaDimmer {
    /// Brightness (0...100, below 100) per dimmed display.
    private(set) var dims: [CGDirectDisplayID: Double] = [:]
    private var keys: [CGDirectDisplayID: String] = [:]
    /// Originals by `DisplayIdentity` key, kept for the run.
    private var originals: [String: GammaRamp] = [:]

    var isActive: Bool { !dims.isEmpty }

    /// Dims `id` (identity `key`) to `brightness` (0...100); 100 restores it.
    func set(_ brightness: Double, for id: CGDirectDisplayID, key: String) {
        guard SoftwareDim.dims(brightness) else {
            restore(id)
            return
        }
        if originals[key] == nil {
            guard let captured = Self.capture(id) else { return }
            let (trusted, suspect) = captured.trustedOriginal()
            if suspect {
                Log.info("displays: \(key)'s gamma table already looked dimmed (peak \(captured.peak)); using it lifted to full as the original")
            }
            originals[key] = trusted
        }
        guard let original = originals[key] else { return }
        dims[id] = brightness
        keys[id] = key
        Self.apply(original.scaled(by: SoftwareDim.factor(forBrightness: brightness)), to: id)
    }

    /// Puts `id`'s original table back (only if Orbit dimmed it).
    func restore(_ id: CGDirectDisplayID) {
        guard dims.removeValue(forKey: id) != nil, let key = keys.removeValue(forKey: id), let original = originals[key] else { return }
        Self.apply(original, to: id)
    }

    /// After a display change or wake: dims the dimmed displays again from their originals, and forgets
    /// displays that are gone.
    func reapply() {
        guard isActive else { return }
        let online = Set(Self.onlineDisplays())
        for (id, brightness) in dims {
            guard online.contains(id), let key = keys[id], let original = originals[key] else {
                dims[id] = nil
                keys[id] = nil
                continue
            }
            Self.apply(original.scaled(by: SoftwareDim.factor(forBrightness: brightness)), to: id)
        }
    }

    /// Restores every display Orbit dimmed (stop, quit).
    func restoreAll() {
        for id in Array(dims.keys) { restore(id) }
    }

    // MARK: CoreGraphics

    private static func capture(_ id: CGDirectDisplayID) -> GammaRamp? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        let n = Int(count)
        return GammaRamp(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    private static func apply(_ ramp: GammaRamp, to id: CGDirectDisplayID) {
        let result = CGSetDisplayTransferByTable(id, UInt32(ramp.red.count), ramp.red, ramp.green, ramp.blue)
        if result != .success { Log.info("displays: CGSetDisplayTransferByTable failed (\(result.rawValue)) for display \(id)") }
    }

    private static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
