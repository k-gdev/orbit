import CoreGraphics
import OrbitCore

/// Software dimming: scales a display's gamma tables (`CGSetDisplayTransferByTable`) for monitors that don't
/// answer DDC. The original tables are captured before the first change and put back when a display goes
/// back to 100, and `restoreAll()` (on `stop()` and quit) hands every display back to ColorSync. macOS also
/// drops a process's gamma changes when it exits, so a crash can't leave a screen dimmed. Nothing here runs
/// unless a display is actually dimmed.
@MainActor
final class GammaDimmer {
    private struct Table {
        var red: [CGGammaValue]
        var green: [CGGammaValue]
        var blue: [CGGammaValue]
    }

    /// Brightness (0...100, below 100) per dimmed display.
    private(set) var dims: [CGDirectDisplayID: Double] = [:]
    private var originals: [CGDirectDisplayID: Table] = [:]

    var isActive: Bool { !dims.isEmpty }

    /// Dims `id` to `brightness` (0...100); 100 restores it.
    func set(_ brightness: Double, for id: CGDirectDisplayID) {
        guard SoftwareDim.dims(brightness) else {
            restore(id)
            return
        }
        if originals[id] == nil { originals[id] = Self.capture(id) }
        guard let original = originals[id] else { return }
        dims[id] = brightness
        Self.apply(original, factor: SoftwareDim.factor(forBrightness: brightness), to: id)
    }

    /// Puts `id`'s original tables back.
    func restore(_ id: CGDirectDisplayID) {
        guard dims.removeValue(forKey: id) != nil else { return }
        if let original = originals.removeValue(forKey: id) { Self.apply(original, factor: 1, to: id) }
        if dims.isEmpty {
            originals.removeAll()
            CGDisplayRestoreColorSyncSettings()
        }
    }

    /// After a display change or wake macOS may have reset the tables (or kept ours): start again from
    /// ColorSync's tables and dim again, dropping displays that are gone.
    func reapply() {
        guard isActive else { return }
        CGDisplayRestoreColorSyncSettings()
        originals.removeAll()
        let online = Set(Self.onlineDisplays())
        for (id, brightness) in dims {
            guard online.contains(id), let original = Self.capture(id) else {
                dims.removeValue(forKey: id)
                continue
            }
            originals[id] = original
            Self.apply(original, factor: SoftwareDim.factor(forBrightness: brightness), to: id)
        }
    }

    /// Hands every display back to ColorSync (only if Orbit dimmed something).
    func restoreAll() {
        guard isActive || !originals.isEmpty else { return }
        dims.removeAll()
        originals.removeAll()
        CGDisplayRestoreColorSyncSettings()
    }

    // MARK: CoreGraphics

    private static func capture(_ id: CGDirectDisplayID) -> Table? {
        let capacity = CGDisplayGammaTableCapacity(id)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red, blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(id, capacity, &red, &green, &blue, &count) == .success, count > 0 else { return nil }
        return Table(red: Array(red.prefix(Int(count))), green: Array(green.prefix(Int(count))), blue: Array(blue.prefix(Int(count))))
    }

    private static func apply(_ table: Table, factor: Double, to id: CGDirectDisplayID) {
        let red = SoftwareDim.scaled(table.red, by: factor)
        let green = SoftwareDim.scaled(table.green, by: factor)
        let blue = SoftwareDim.scaled(table.blue, by: factor)
        let result = CGSetDisplayTransferByTable(id, UInt32(red.count), red, green, blue)
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
