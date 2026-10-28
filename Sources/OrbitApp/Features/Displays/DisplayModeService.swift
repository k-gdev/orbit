import CoreGraphics
import OrbitCore

/// A display's resolutions: every mode macOS offers (including the HiDPI ones, via
/// `kCGDisplayShowDuplicateLowResolutionModes`), turned into a menu by `DisplayModeList`, and switching
/// to one with a permanent display configuration (it survives logout, like System Settings).
///
/// Orbit lists only what macOS offers. HiDPI or virtual modes that other tools add through
/// `/Library/Displays` overrides or virtual screens show up here while those exist; Orbit never writes them.
enum DisplayModeService {
    private static var options: CFDictionary {
        [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue as Any] as CFDictionary
    }

    /// The menu for `id`.
    static func list(for id: CGDirectDisplayID) -> DisplayModeList {
        let modes = allModes(id).map(RawDisplayMode.init)
        let current = CGDisplayCopyDisplayMode(id).map(RawDisplayMode.init)
        return DisplayModeList(modes: modes, current: current)
    }

    /// Switches `id` to `mode`. Returns false when the mode is gone or CoreGraphics refused.
    @discardableResult
    static func apply(_ mode: RawDisplayMode, to id: CGDirectDisplayID) -> Bool {
        guard let target = allModes(id).first(where: { RawDisplayMode($0) == mode }) else {
            Log.info("displays: mode \(mode.width)x\(mode.height) is no longer offered by display \(id)")
            return false
        }
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return false }
        guard CGConfigureDisplayWithDisplayMode(config, id, target, nil) == .success else {
            CGCancelDisplayConfiguration(config)
            return false
        }
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success { Log.info("displays: CGCompleteDisplayConfiguration failed (\(result.rawValue))") }
        return result == .success
    }

    private static func allModes(_ id: CGDirectDisplayID) -> [CGDisplayMode] {
        (CGDisplayCopyAllDisplayModes(id, options) as? [CGDisplayMode]) ?? []
    }
}

extension RawDisplayMode {
    init(_ mode: CGDisplayMode) {
        self.init(id: mode.ioDisplayModeID, width: mode.width, height: mode.height, pixelWidth: mode.pixelWidth,
                  pixelHeight: mode.pixelHeight, refreshRate: mode.refreshRate, isUsable: mode.isUsableForDesktopGUI(),
                  ioFlags: mode.ioFlags)
    }
}
