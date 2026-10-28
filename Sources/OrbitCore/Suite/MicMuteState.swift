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

/// How the mic looks right now (the shared mute's live state, spec §8.3).
public enum MicMutePresentation: Equatable, Sendable {
    /// No input device, or one Orbit can neither mute nor turn down.
    case unavailable
    case unmuted
    /// Orbit's mute is in effect.
    case mutedByOrbit
    /// The device's own mute is on, but Orbit didn't set it (System Settings, the headset's button).
    case mutedElsewhere
}

/// Keeps Orbit's own mute and unmute writes from being misread while they land.
///
/// `AudioObjectSetPropertyData` may take effect asynchronously, so a reading taken right after one of Orbit's
/// writes can still show the device as it was: after a mute, "unmuted" (which must not be taken for the user
/// unmuting elsewhere, or Orbit would forget its mute); after an unmute, "muted" (which must not flash
/// "Muted outside Orbit", or make a quick second press unmute again). After `wrote(_:at:)`, a reading of that
/// device that doesn't show the write yet is projected to what the write will leave and marked untrusted
/// (nothing may be concluded from it), until a reading confirms the write or `timeout` passes (then the write
/// evidently didn't take, and the device's own state shows again).
public struct MicWriteConfirmation: Equatable, Sendable {
    public static let timeout: TimeInterval = 2

    private var written: [MicMuteAction] = []
    private var since: Date?

    public init() {}

    /// A write of Orbit's is waiting to show up.
    public var isWaiting: Bool { since != nil }

    /// Orbit just wrote `actions`. Writing nothing changes nothing: a write still landing keeps its wait (ending it
    /// would let that write's late arrival be taken for a change made outside Orbit).
    public mutating func wrote(_ actions: [MicMuteAction], at now: Date) {
        guard !actions.isEmpty else { return }
        written = actions
        since = now
    }

    /// A fresh reading as it should be shown, and whether it may be taken at face value (fed to
    /// `MicMuteState.deviceChanged`). Readings of other devices pass through untouched.
    public mutating func review(_ reading: MicDeviceReading, now: Date) -> (reading: MicDeviceReading, trusted: Bool) {
        guard let since else { return (reading, true) }
        let mine = written.filter { Self.device(of: $0) == reading.deviceUID }
        guard !mine.isEmpty else { return (reading, true) }
        if mine.allSatisfy({ Self.shows($0, in: reading) }) || now.timeIntervalSince(since) >= Self.timeout {
            written = []
            self.since = nil
            return (reading, true)
        }
        var projected = reading
        for action in mine {
            switch action {
            case .setMute(_, let muted): projected.isMuted = muted
            case .setVolume(_, let volume): projected.volume = volume
            }
        }
        return (projected, false)
    }

    private static func device(of action: MicMuteAction) -> String {
        switch action {
        case .setMute(let uid, _), .setVolume(let uid, _): uid
        }
    }

    private static func shows(_ action: MicMuteAction, in reading: MicDeviceReading) -> Bool {
        switch action {
        case .setMute(_, let muted): reading.isMuted == muted
        case .setVolume(_, let volume): reading.volume.map { abs($0 - volume) < 0.01 } ?? false
        }
    }
}

/// The logic of the shared mic mute (Sound and Controls, spec §8.3), free of Core Audio so it can be tested.
///
/// Muting uses the device's mute control when it has one, otherwise turns its input volume to 0. Either way
/// the state records what the device was like before. Undoing is two steps, because the write can fail:
/// `restoreActions()` says what to write, and `commitRestore()` forgets the record once every write took.
/// Until then the record (and the mute) stay. A muted device that is unplugged, or that can't be put back
/// right now, is `setAside()` into `pending`; `pendingWork` undoes it when the device is back, provided it is
/// still exactly as Orbit left it. A mic that was already muted, or at volume 0, before Orbit's mute is left
/// that way: Orbit never "restores" a mute it did not apply. Codable, so the app keeps the record across a
/// crash and finishes the job on the next launch (`fromPreviousRun`).
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
    /// Mutes Orbit applied to devices that went away, or couldn't be put back yet: undone when possible.
    public private(set) var pending: [Applied] = []

    public init() {}

    /// Whether Orbit's mute is in effect.
    public var isMuted: Bool { applied != nil }

    /// The device Orbit muted.
    public var deviceUID: String? { applied?.deviceUID }

    /// Whether there is anything to keep across a crash: a mute in effect or one waiting to be undone.
    public var hasRecord: Bool { applied != nil || !pending.isEmpty }

    /// Volumes at or below this count as silent.
    private static let silent: Float = 0.001

    // MARK: Muting

    /// Mutes the device described by `reading` and remembers its previous state. Returns the actions to
    /// perform (empty when Orbit's mute is already in effect, or the device was already silent), or nil
    /// when the device can't be muted at all. A device still on record in `pending` keeps that original
    /// state, so the later unmute really puts it back.
    public mutating func mute(_ reading: MicDeviceReading) -> [MicMuteAction]? {
        guard applied == nil else { return [] }
        if let index = pending.firstIndex(where: { $0.deviceUID == reading.deviceUID }) {
            let earlier = pending.remove(at: index)
            applied = earlier
            switch earlier.method {
            case .muteFlag:
                return reading.canSetMute && !reading.isMuted ? [.setMute(deviceUID: reading.deviceUID, muted: true)] : []
            case .volume:
                let quiet = (reading.volume ?? 0) <= Self.silent
                return reading.canSetVolume && !quiet ? [.setVolume(deviceUID: reading.deviceUID, volume: 0)] : []
            }
        }
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

    // MARK: Unmuting

    /// The actions that put the muted device back as it was before Orbit's mute (none when Orbit's mute is not
    /// in effect, or the mic was already muted before it). Does not forget anything: write them, then call
    /// `commitRestore()` once they all took; on failure keep the state (and the mute) as it is.
    public func restoreActions() -> [MicMuteAction] {
        applied.map(Self.undo) ?? []
    }

    /// The restore was written: Orbit's mute is over.
    public mutating func commitRestore() {
        applied = nil
    }

    /// `restoreActions()` and `commitRestore()` in one, for callers whose writes can't fail.
    public mutating func restore() -> [MicMuteAction] {
        let actions = restoreActions()
        commitRestore()
        return actions
    }

    /// The muted device is gone (or can't be put back now): keep its record in `pending` and end Orbit's mute.
    public mutating func setAside() {
        guard let applied else { return }
        if !pending.contains(where: { $0.deviceUID == applied.deviceUID }) { pending.append(applied) }
        self.applied = nil
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

    // MARK: Readings taken while Orbit's own writes land

    /// `mute(_:)` for a fresh reading of the device, taken while one of Orbit's own writes may still be landing: the
    /// mute is built from the device as that write will leave it (`MicWriteConfirmation.review`), not from the stale
    /// reading. Right after Orbit's unmute the device can still read muted; muting from that would record "muted
    /// before Orbit" and write nothing, and the unmute landing afterwards would look like the user unmuting
    /// elsewhere, leaving the mic live although the last press was a mute.
    public mutating func mute(_ reading: MicDeviceReading, confirming confirmation: inout MicWriteConfirmation,
                              now: Date) -> [MicMuteAction]? {
        mute(confirmation.review(reading, now: now).reading)
    }

    /// A fresh reading of the input device, reviewed against Orbit's own writes still landing: the reading to show,
    /// and whether it shows that the user unmuted Orbit's mute outside Orbit (Orbit's mute is then over, with nothing
    /// to restore). Only a reading that may be taken at face value can say so.
    public mutating func observe(_ reading: MicDeviceReading, confirming confirmation: inout MicWriteConfirmation,
                                 now: Date) -> (shown: MicDeviceReading, unmutedOutside: Bool) {
        let reviewed = confirmation.review(reading, now: now)
        guard reviewed.trusted, isMuted else { return (reviewed.reading, false) }
        return (reviewed.reading, !deviceChanged(reviewed.reading))
    }

    // MARK: Pending records

    /// For each pending record whose device is connected (`reading` returns it): the actions that undo
    /// Orbit's mute, empty when the device is no longer as Orbit left it (nothing to write; resolve it).
    /// Devices that are not connected are left out (keep waiting).
    public func pendingWork(reading: (String) -> MicDeviceReading?) -> [(deviceUID: String, actions: [MicMuteAction])] {
        pending.compactMap { entry in
            guard let current = reading(entry.deviceUID), current.deviceUID == entry.deviceUID else { return nil }
            return (entry.deviceUID, Self.recoveryActions(for: entry, current: current))
        }
    }

    /// The pending record for this device was dealt with (written, or found changed by the user).
    public mutating func resolvePending(deviceUID: String) {
        pending.removeAll { $0.deviceUID == deviceUID }
    }

    /// The state a new launch starts from, given the record the previous run left: nothing is in effect any
    /// more, everything it had is pending.
    public static func fromPreviousRun(_ record: MicMuteState) -> MicMuteState {
        var state = MicMuteState()
        state.pending = record.pending
        if let applied = record.applied, !state.pending.contains(where: { $0.deviceUID == applied.deviceUID }) {
            state.pending.append(applied)
        }
        return state
    }

    /// The actions that undo `entry` on its device as it is now: only while the device is still exactly as
    /// Orbit left it (muted, or at volume 0), and never for a mute that was there before Orbit's.
    public static func recoveryActions(for entry: Applied, current: MicDeviceReading) -> [MicMuteAction] {
        switch entry.method {
        case .muteFlag:
            guard current.canSetMute, current.isMuted else { return [] }
        case .volume:
            guard current.canSetVolume, let volume = current.volume, volume <= silent else { return [] }
        }
        return undo(entry)
    }

    // MARK: Live state

    /// How the mic looks now, for the UI: Orbit's mute (in effect even while the device can't be read), a
    /// mute made outside Orbit, unmuted, or nothing Orbit can mute.
    public func presentation(for reading: MicDeviceReading?) -> MicMutePresentation {
        if let applied, reading == nil || reading?.deviceUID == applied.deviceUID { return .mutedByOrbit }
        guard let reading, reading.canSetMute || reading.canSetVolume else { return .unavailable }
        return reading.canSetMute && reading.isMuted ? .mutedElsewhere : .unmuted
    }

    /// Whether `reading` shows Orbit's mute in effect on its device: the mute control on, or (volume mute) the
    /// volume at 0. False for another device, or when Orbit's mute is not in effect.
    public func reflects(_ reading: MicDeviceReading) -> Bool {
        guard let applied, applied.deviceUID == reading.deviceUID else { return false }
        switch applied.method {
        case .muteFlag: return reading.isMuted
        case .volume: return (reading.volume ?? 1) <= Self.silent
        }
    }

    /// The user asked to unmute a mic that was muted outside Orbit: switch its mute control off (a direct user
    /// action, never done on Orbit's own initiative). Empty when there's nothing to unmute.
    public static func directUnmute(_ reading: MicDeviceReading) -> [MicMuteAction] {
        reading.canSetMute && reading.isMuted ? [.setMute(deviceUID: reading.deviceUID, muted: false)] : []
    }

    private static func undo(_ applied: Applied) -> [MicMuteAction] {
        switch applied.method {
        case .muteFlag(let wasMuted):
            return wasMuted ? [] : [.setMute(deviceUID: applied.deviceUID, muted: false)]
        case .volume(let previous):
            return previous <= silent ? [] : [.setVolume(deviceUID: applied.deviceUID, volume: previous)]
        }
    }

    // MARK: Codable (records written before `pending` existed still decode)

    private enum CodingKeys: String, CodingKey {
        case applied, pending
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        applied = try c.decodeIfPresent(Applied.self, forKey: .applied)
        pending = try c.decodeIfPresent([Applied].self, forKey: .pending) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(applied, forKey: .applied)
        try c.encode(pending, forKey: .pending)
    }
}
