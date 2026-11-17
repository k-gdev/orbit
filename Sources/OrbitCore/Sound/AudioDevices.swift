import Foundation

/// How an audio device is connected (`kAudioDevicePropertyTransportType`).
public enum AudioTransport: Sendable, Equatable {
    case builtIn, usb, bluetooth, bluetoothLE, hdmi, displayPort, airPlay, thunderbolt, virtual, aggregate,
         pci, fireWire, avb, unknown

    /// From Core Audio's four-character transport code ('bltn', 'usb ', 'dprt', ...).
    public init(fourCC: UInt32) {
        switch fourCC {
        case Self.code("bltn"): self = .builtIn
        case Self.code("usb "): self = .usb
        case Self.code("blue"): self = .bluetooth
        case Self.code("blea"): self = .bluetoothLE
        case Self.code("hdmi"): self = .hdmi
        case Self.code("dprt"): self = .displayPort
        case Self.code("airp"): self = .airPlay
        case Self.code("thun"): self = .thunderbolt
        case Self.code("virt"): self = .virtual
        case Self.code("grup"): self = .aggregate
        case Self.code("pci "): self = .pci
        case Self.code("1394"): self = .fireWire
        case Self.code("eavb"): self = .avb
        default: self = .unknown
        }
    }

    private static func code(_ text: String) -> UInt32 {
        text.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// What the Sound tab needs to know about an audio device.
public struct AudioDeviceSummary: Identifiable, Equatable, Sendable {
    /// The persistent `kAudioDevicePropertyDeviceUID`.
    public var uid: String
    public var name: String
    public var inputChannels: Int
    public var outputChannels: Int
    public var transport: AudioTransport

    public init(uid: String, name: String, inputChannels: Int, outputChannels: Int, transport: AudioTransport) {
        self.uid = uid
        self.name = name
        self.inputChannels = inputChannels
        self.outputChannels = outputChannels
        self.transport = transport
    }

    public var id: String { uid }
    public var hasInput: Bool { inputChannels > 0 }
    public var hasOutput: Bool { outputChannels > 0 }

    /// An SF Symbol for menus and pop-up buttons: a laptop for built-in devices, headphones for headsets
    /// and Bluetooth headphones (AirPods by model), a display for HDMI/DisplayPort audio, a waveform for
    /// virtual devices; otherwise a speaker (output) or microphone (input).
    public func symbol(forInput: Bool) -> String {
        let lower = name.lowercased()
        switch transport {
        case .builtIn:
            return "laptopcomputer"
        case .hdmi, .displayPort:
            return "display"
        case .bluetooth, .bluetoothLE:
            if lower.contains("airpods max") { return "airpodsmax" }
            if lower.contains("airpods pro") { return "airpodspro" }
            if lower.contains("airpods") { return "airpods" }
            return "headphones"
        case .airPlay:
            return "airplayaudio"
        case .virtual:
            return "waveform"
        case .aggregate:
            return "square.stack.3d.up"
        default:
            if Self.headsetWords.contains(where: lower.contains) { return "headphones" }
            return forInput ? "mic" : "hifispeaker"
        }
    }

    private static let headsetWords = ["headset", "headphone", "arctis", "steelseries", "airpods", "earbuds", "buds",
                                       "hyperx", "jabra", "beats"]
}

/// Names for device menus.
public enum AudioDeviceNaming {
    /// UID → the name to show: the device's own name, numbered when several devices share it ("P27u-20",
    /// "P27u-20 (2)", in list order), or "Unnamed device".
    public static func displayNames(for devices: [AudioDeviceSummary]) -> [String: String] {
        var seen: [String: Int] = [:]
        var names: [String: String] = [:]
        for device in devices {
            let base = device.name.trimmingCharacters(in: .whitespaces).isEmpty ? "Unnamed device" : device.name
            let count = (seen[base] ?? 0) + 1
            seen[base] = count
            names[device.uid] = count == 1 ? base : "\(base) (\(count))"
        }
        return names
    }
}

/// "Keep preferred microphone": when to switch the input device back.
public enum PreferredMicPolicy {
    /// True when `keep` is on, a preferred mic is set, the current input is something else, and the
    /// preferred mic is connected (in `availableUIDs`).
    public static func shouldSwitchBack(currentUID: String?, preferredUID: String?, availableUIDs: Set<String>, keep: Bool) -> Bool {
        guard keep, let preferredUID, !preferredUID.isEmpty else { return false }
        return currentUID != preferredUID && availableUIDs.contains(preferredUID)
    }

    /// At most one switch per this many seconds, so a device that refuses can't start a tug of war.
    public static let throttle: TimeInterval = 2

    /// Nil when a switch may happen now; otherwise how long until the throttle window after `lastSwitch` ends,
    /// when the check should run again (a change inside the window is retried, not dropped).
    public static func retryDelay(lastSwitch: Date, now: Date) -> TimeInterval? {
        let elapsed = now.timeIntervalSince(lastSwitch)
        return elapsed > throttle ? nil : throttle - max(elapsed, 0)
    }
}
