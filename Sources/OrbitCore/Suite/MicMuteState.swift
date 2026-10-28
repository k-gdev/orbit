import Foundation

/// What Orbit reads from the input device before muting it (or while it is muted).
public struct MicDeviceReading: Equatable, Sendable {
    public var deviceUID: String
    /// The device has a mute control Orbit can set.
    public var canSetMute: Bool
    /// The mute control's current value (false without one).
    public var isMuted: Bool
    /// The device has an input volume Orbit can set.
    public var canSetVolume: Bool
    /// The input volume, 0…1, if the device reports one.
    public var volume: Float?

    public init(deviceUID: String, canSetMute: Bool, isMuted: Bool, canSetVolume: Bool, volume: Float?) {
        self.deviceUID = deviceUID
        self.canSetMute = canSetMute
        self.isMuted = isMuted
        self.canSetVolume = canSetVolume
        self.volume = volume
    }
}

/// One change to make on an input device.
public enum MicMuteAction: Equatable, Sendable {
    case setMute(deviceUID: String, muted: Bool)
    case setVolume(deviceUID: String, volume: Float)
}

/// The logic of the shared mic mute (Sound and Controls, spec §8.3), free of Core Audio so it can be tested.
///
/// Muting uses the device's mute control when it has one, otherwise turns its input volume to 0. Either
/// way the state records what the device was like before, and `restore()` (unmute, turning the feature
/// off, quitting) returns exactly the actions that put that back. A mic that was already muted, or at
/// volume 0, before Orbit's mute is left that way: Orbit never "restores" a mute it did not apply.
/// Codable so the app can keep the record across a crash and undo it on the next launch
/// (`recoveryActions`).
public struct MicMuteState: Codable, Equatable, Sendable {
    /// How Orbit muted the device, with what it needs to undo it.
    public enum Method: Codable, Equatable, Sendable {
        /// Set the device's mute control; `wasMuted` is its value before.
        case muteFlag(wasMuted: Bool)
        /// Turned the input volume to 0 from `previous`.
        case volume(previous: Float)
    }

    public struct Applied: Codable, Equatable, Sendable {
        public var deviceUID: String
        public var method: Method
    }

    /// What Orbit's mute did, while it is in effect.
    public private(set) var applied: Applied?

    public init() {}

    /// Whether Orbit's mute is in effect.
    public var isMuted: Bool { applied != nil }

    /// The device Orbit muted.
    public var deviceUID: String? { applied?.deviceUID }

    /// Volumes at or below this count as silent.
    private static let silent: Float = 0.001

    /// Mutes the device described by `reading` and remembers its previous state. Returns the actions to
    /// perform (empty when Orbit's mute is already in effect, or the device was already silent), or nil
    /// when the device can't be muted at all.
    public mutating func mute(_ reading: MicDeviceReading) -> [MicMuteAction]? {
        guard applied == nil else { return [] }
        if reading.canSetMute {
            applied = Applied(deviceUID: reading.deviceUID, method: .muteFlag(wasMuted: reading.isMuted))
            return reading.isMuted ? [] : [.setMute(deviceUID: reading.deviceUID, muted: true)]
        }
        if reading.canSetVolume, let volume = reading.volume {
            applied = Applied(deviceUID: reading.deviceUID, method: .volume(previous: volume))
            return volume <= Self.silent ? [] : [.setVolume(deviceUID: reading.deviceUID, volume: 0)]
        }
        return nil
    }

    /// Ends Orbit's mute: the actions that put the device back as it was before (none when Orbit's mute is
    /// not in effect, or the mic was already muted before it). Forgets the record.
    public mutating func restore() -> [MicMuteAction] {
        guard let applied else { return [] }
        self.applied = nil
        return Self.undo(applied)
    }

    /// The default input device changed to `reading` (nil: none) while Orbit's mute is in effect: put the old
    /// device back and mute the new one. When the new one can't be muted, the mute ends. No change of device,
    /// or no mute in effect: nothing to do.
    public mutating func retarget(to reading: MicDeviceReading?) -> [MicMuteAction] {
        guard let applied, applied.deviceUID != reading?.deviceUID else { return [] }
        var actions = restore()
        if let reading, let muting = mute(reading) { actions += muting }
        return actions
    }

    /// The muted device changed outside Orbit. When the user unmuted it (mute control cleared, or volume
    /// raised from 0) Orbit stops holding the mute, with nothing to restore. Readings of other devices are
    /// ignored. Returns whether Orbit's mute is still in effect.
    @discardableResult
    public mutating func deviceChanged(_ reading: MicDeviceReading) -> Bool {
        guard let applied, applied.deviceUID == reading.deviceUID else { return isMuted }
        switch applied.method {
        case .muteFlag:
            if !reading.isMuted { self.applied = nil }
        case .volume:
            if let volume = reading.volume, volume > Self.silent { self.applied = nil }
        }
        return isMuted
    }

    /// For a record left by a previous run (a crash while muted): the actions that undo it, provided the
    /// device is connected and still exactly as Orbit left it (muted, or at volume 0). Otherwise none.
    public static func recoveryActions(for record: MicMuteState, current: MicDeviceReading?) -> [MicMuteAction] {
        guard let applied = record.applied, let current, current.deviceUID == applied.deviceUID else { return [] }
        switch applied.method {
        case .muteFlag:
            guard current.canSetMute, current.isMuted else { return [] }
        case .volume:
            guard current.canSetVolume, let volume = current.volume, volume <= silent else { return [] }
        }
        return undo(applied)
    }

    private static func undo(_ applied: Applied) -> [MicMuteAction] {
        switch applied.method {
        case .muteFlag(let wasMuted):
            return wasMuted ? [] : [.setMute(deviceUID: applied.deviceUID, muted: false)]
        case .volume(let previous):
            return previous <= silent ? [] : [.setVolume(deviceUID: applied.deviceUID, volume: previous)]
        }
    }
}
