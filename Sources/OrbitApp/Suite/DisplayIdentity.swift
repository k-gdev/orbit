import AppKit
import CoreGraphics

/// A stable key for a physical display, shared by Displays and Wallpaper so per-display settings line up.
/// `CGDirectDisplayID`s change across reboots and reconnects; the key below survives them.
enum DisplayIdentity {
    /// The display's UUID string (`CGDisplayCreateUUIDFromDisplayID`), or `"<vendor>-<model>-<serial>"`
    /// from the EDID numbers when macOS has no UUID for it.
    static func key(for id: CGDirectDisplayID) -> String {
        if let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
           let text = CFUUIDCreateString(nil, uuid) as String? {
            return text
        }
        return "\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
    }

    /// The `CGDirectDisplayID` behind an `NSScreen` (its `NSScreenNumber`).
    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    /// The key for an `NSScreen`, or nil when it has no display id.
    static func key(for screen: NSScreen) -> String? {
        displayID(for: screen).map { key(for: $0) }
    }
}
