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

    /// The device the action writes to.
    public var deviceUID: String {
        switch self {
        case .setMute(let uid, _), .setVolume(let uid, _): uid
        }
    }
}

extension MicDeviceReading {
    /// The reading as `actions` will leave it (actions for other devices change nothing).
    public func applying(_ actions: [MicMuteAction]) -> MicDeviceReading {
        var reading = self
        for action in actions where action.deviceUID == deviceUID {
            switch action {
            case .setMute(_, let muted): reading.isMuted = muted
            case .setVolume(_, let volume): reading.volume = volume
            }
        }
        return reading
    }
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

/// Orbit's own mic writes that haven't shown yet, so they aren't misread while they land.
///
/// `AudioObjectSetPropertyData` may take effect asynchronously, so a reading taken right after one of Orbit's writes
/// can still show the device as it was: after a mute, "unmuted" (which must not be taken for the user unmuting
/// elsewhere, or Orbit would forget its mute); after an unmute, "muted" (which must not flash "Muted outside Orbit").
/// After `wrote(_:undoing:at:)`, `review` shows a reading of that device as the write will leave it and marks it
/// untrusted (nothing may be concluded from it) until a reading shows the write's own value, or `timeout` passes (the
/// write evidently didn't take; the device counts as it reads again). A reading never confirms any other value.
///
/// A write waits until a reading of its own device settles it (shown, or timed out) or the device is gone (`forget`):
/// a reading of another device says nothing about it. `MicMuteModel` reads every device with a write waiting and never
/// writes to a device while one waits, so there is at most one write per device here. An undo that times out hands
/// back the mute it was undoing (`Review.undosNotShown`), so the model can tell whether that mute is still in effect.
///
/// Times are on the monotonic `ContinuousClock` (time asleep counts), so a change of the wall clock can't stretch a
/// wait or end one early.
public struct MicWriteConfirmation: Equatable, Sendable {
    public static let timeout: Duration = .seconds(2)

    /// One write of Orbit's that hasn't shown yet, and when it was made.
    private struct Written: Equatable, Sendable {
        var action: MicMuteAction
        var at: ContinuousClock.Instant
        /// For an undo: the mute of Orbit's it undoes, handed back if the undo never shows.
        var undoing: MicMuteState.Applied?
    }

    private var written: [Written] = []

    public init() {}

    /// A write of Orbit's is waiting to show up (or to be found timed out).
    public var isWaiting: Bool { !written.isEmpty }

    /// A write of Orbit's to this device is waiting: nothing else may be written to it yet.
    public func isWaiting(on deviceUID: String) -> Bool {
        written.contains { $0.action.deviceUID == deviceUID }
    }

    /// The devices with a write waiting, in the order they were first written to.
    public var waitingDevices: [String] {
        var seen: Set<String> = []
        return written.map(\.action.deviceUID).filter { seen.insert($0).inserted }
    }

    /// When the earliest waiting write times out: a fresh look then settles it even if no listener fires.
    public var nextDeadline: ContinuousClock.Instant? {
        written.map { $0.at + Self.timeout }.min()
    }

    /// Every write to this device has passed its timeout.
    public func hasTimedOut(deviceUID: String, now: ContinuousClock.Instant) -> Bool {
        written.allSatisfy { $0.action.deviceUID != deviceUID || now - $0.at >= Self.timeout }
    }

    /// Orbit just wrote `actions` (`undoing`: the mute they undo, if any). Each replaces an earlier write of the same
    /// control on the same device (the device will show the later one). Writing nothing changes nothing: a write still
    /// landing keeps its wait.
    public mutating func wrote(_ actions: [MicMuteAction], undoing: MicMuteState.Applied? = nil, at now: ContinuousClock.Instant) {
        for action in actions {
            written.removeAll { Self.sameControl($0.action, action) }
            written.append(Written(action: action, at: now, undoing: undoing))
        }
    }

    /// What a fresh reading of a device says, given Orbit's writes to it.
    public struct Review: Equatable, Sendable {
        /// The reading as it should be shown: as Orbit's writes still waiting will leave it.
        public var reading: MicDeviceReading
        /// No write of Orbit's to the device waits any more: the reading counts at face value.
        public var trusted: Bool
        /// This review ended the device's wait (its writes showed, or timed out): what waited for it may go ahead.
        public var settled: Bool
        /// Writes that timed out without showing: they evidently didn't take.
        public var timedOut: [MicMuteAction]
        /// The mutes whose undo timed out without showing.
        public var undosNotShown: [MicMuteState.Applied]
    }

    /// Reviews a fresh reading: a write it shows is confirmed, a write past its timeout didn't take, the rest keep
    /// waiting (and the reading is shown as they will leave it). Readings of devices with nothing waiting pass through.
    public mutating func review(_ reading: MicDeviceReading, now: ContinuousClock.Instant) -> Review {
        let uid = reading.deviceUID
        let mine = written.filter { $0.action.deviceUID == uid }
        guard !mine.isEmpty else {
            return Review(reading: reading, trusted: true, settled: false, timedOut: [], undosNotShown: [])
        }
        var waiting: [Written] = []
        var timedOut: [Written] = []
        for entry in mine where !Self.shows(entry.action, in: reading) {
            if now - entry.at >= Self.timeout { timedOut.append(entry) } else { waiting.append(entry) }
        }
        written.removeAll { $0.action.deviceUID == uid && !waiting.contains($0) }
        return Review(reading: reading.applying(waiting.map(\.action)), trusted: waiting.isEmpty, settled: waiting.isEmpty,
                      timedOut: timedOut.map(\.action), undosNotShown: Self.records(timedOut))
    }

    /// A reading as Orbit's writes to its device, shown or not, will leave it (nothing is settled).
    public func projected(_ reading: MicDeviceReading) -> MicDeviceReading {
        reading.applying(written.map(\.action))
    }

    /// The device is gone: its writes stop waiting. Returns the mutes they were undoing (whether those undos took is
    /// unknown).
    public mutating func forget(deviceUID: String) -> [MicMuteState.Applied] {
        let mine = written.filter { $0.action.deviceUID == deviceUID }
        written.removeAll { $0.action.deviceUID == deviceUID }
        return Self.records(mine)
    }

    private static func records(_ entries: [Written]) -> [MicMuteState.Applied] {
        var records: [MicMuteState.Applied] = []
        for record in entries.compactMap(\.undoing) where !records.contains(record) { records.append(record) }
        return records
    }

    private static func sameControl(_ a: MicMuteAction, _ b: MicMuteAction) -> Bool {
        switch (a, b) {
        case (.setMute(let x, _), .setMute(let y, _)), (.setVolume(let x, _), .setVolume(let y, _)): x == y
        default: false
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

    /// An undo of `record` was written but never showed, and its device still reads exactly as Orbit left it: Orbit's
    /// mute is still in effect there. It becomes the mute in effect again when its device is the input (`asInput`) and
    /// no other is; otherwise it waits in `pending` to be undone.
    public mutating func takeBack(_ record: Applied, asInput: Bool) {
        guard applied?.deviceUID != record.deviceUID else { return }
        if asInput, applied == nil {
            pending.removeAll { $0.deviceUID == record.deviceUID }
            applied = record
        } else if !pending.contains(where: { $0.deviceUID == record.deviceUID }) {
            pending.append(record)
        }
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

    /// What undoes `applied` on its device (nothing for a mute or zero volume that was there before Orbit's).
    static func undo(_ applied: Applied) -> [MicMuteAction] {
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
