import Foundation

/// Mics whose mute and input volume Core Audio reports, accepts and reads back, yet that keep sending sound anyway:
/// nothing on the Mac can mute them, only their own mute button. Orbit treats them as having neither control, so it
/// never shows one as muted. Only models tested on hardware are listed.
public enum MicsIgnoringMute {
    /// The "vendor:product" (hex) a USB mic's Core Audio model UID ends with ("<name>:1038:2232").
    static let usbIDs: Set<String> = [
        "1038:2232", // SteelSeries Arctis Nova 5 (its USB base station), tested 28 Oct 2026
    ]

    /// Whether the mic with this Core Audio model UID ignores its mute and input volume.
    public static func contains(modelUID: String?) -> Bool {
        guard let parts = modelUID?.lowercased().split(separator: ":", omittingEmptySubsequences: false),
              parts.count >= 3 else { return false }
        return usbIDs.contains(parts.suffix(2).joined(separator: ":"))
    }
}

extension MicDeviceReading {
    /// This reading as Orbit can use it: a mic in `MicsIgnoringMute` has no mute or input volume worth setting. It
    /// still reads as it is.
    public func usable(modelUID: String?) -> MicDeviceReading {
        guard MicsIgnoringMute.contains(modelUID: modelUID) else { return self }
        var reading = self
        reading.canSetMute = false
        reading.canSetVolume = false
        return reading
    }
}
