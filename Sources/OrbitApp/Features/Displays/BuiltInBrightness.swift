import CoreGraphics
import OrbitCore

/// Brightness of the built-in panel (and Apple-made external displays such as the Studio Display) through
/// the private DisplayServices framework, reached only via `PrivateSymbol`: a missing symbol makes the
/// display "not controllable here", never a crash. Third-party monitors answer `canControl` with false
/// (checked on Kevo's Mac: all four externals), so they go to DDC.
enum BuiltInBrightness {
    static let framework = "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    private typealias CanChange = @convention(c) (CGDirectDisplayID) -> Bool
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    /// Whether DisplayServices drives `id`'s backlight.
    static func canControl(_ id: CGDirectDisplayID) -> Bool {
        if let canChange = PrivateSymbol.load("DisplayServicesCanChangeBrightness", from: framework, as: CanChange.self) {
            return canChange(id)
        }
        return CGDisplayIsBuiltin(id) != 0 && brightness(of: id) != nil
    }

    /// The brightness, 0...100, or nil when DisplayServices can't read it.
    static func brightness(of id: CGDirectDisplayID) -> Double? {
        guard let get = PrivateSymbol.load("DisplayServicesGetBrightness", from: framework, as: Get.self) else { return nil }
        var value: Float = 0
        guard get(id, &value) == 0, value.isFinite else { return nil }
        return Double(min(max(value, 0), 1)) * 100
    }

    /// Sets the brightness (0...100, clamped). Returns false when DisplayServices refused or is missing.
    @discardableResult
    static func setBrightness(_ value: Double, of id: CGDirectDisplayID) -> Bool {
        guard let set = PrivateSymbol.load("DisplayServicesSetBrightness", from: framework, as: Set.self) else { return false }
        let fraction = Float(min(max(value.isFinite ? value : 100, 0), 100) / 100)
        return set(id, fraction) == 0
    }
}
