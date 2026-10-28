import Foundation

/// The shared mic mute as a whole (spec §8.3), free of Core Audio: Orbit's record (`MicMuteState`), its writes still
/// landing (`MicWriteConfirmation`), and what the user asked for that hasn't been written yet (`wish`).
///
/// `MicMuteService` hands it fresh readings and carries out the writes it asks for (`perform`), always in this order:
/// an action (`press`, `release`, `inputChanged`) followed by a `refresh` with a new reading of the input; a `refresh`
/// for every change the input's listeners report; and one at `nextCheck`. Every decision is made here, so tests can
/// replay that call order exactly.
///
/// The rule that keeps Orbit from losing track of its own mute: **Orbit never writes to a mic while an earlier write
/// of its own to that mic hasn't shown yet.** A press in that window only sets the wish, shown at once. Once the
/// earlier write shows (a reading has its value) or times out, the mic's reading counts again, and the wish is carried
/// out if it still differs from what Orbit has applied. A reading taken while a write lands is shown as that write
/// will leave it, never confirms another value, and is never taken for an unmute made outside Orbit.
///
/// A write that times out evidently didn't take, and the mic counts as it reads, so the UI shows the truth:
/// - Orbit's mute that never showed is over; there's nothing to undo.
/// - An undo that never showed, with the mic still exactly as Orbit left it, leaves Orbit's mute in effect. Its
///   record is kept (shown muted, undone by the next unmute, on disable and on quit, and kept across a crash).
///
/// Neither is retried on Orbit's own initiative, so there is no retry loop: the only writes made without a fresh
/// request are a wish waiting for its mic, and a mic put back once Orbit's write to it has shown.
public struct MicMuteModel: Equatable, Sendable {
    /// What the user asked for that waits to be written.
    public enum Wish: Equatable, Sendable {
        /// Orbit's mute on the input.
        case mute
        /// A press to unmute: undo Orbit's mute, or switch off a mute made outside Orbit.
        case unmute
        /// Undo Orbit's own mute only (going inactive, the badge); a mute made outside Orbit stays.
        case release
    }

    /// What happened, for the log.
    public enum Event: Equatable, Sendable {
        /// No input device, or one Orbit can neither mute nor turn down.
        case cannotMute
        /// A press waits for Orbit's earlier write to this mic to show.
        case waiting(deviceUID: String)
        case muteFailed(deviceUID: String)
        /// Undoing Orbit's mute failed: the mute and its record stay, to be tried again.
        case undoFailed(deviceUID: String)
        /// Switching off a mute made outside Orbit failed.
        case unmuteFailed(deviceUID: String)
        /// Orbit's mute never showed within the timeout and the mic reads unmuted: Orbit's mute is over.
        case muteDidNotTake(deviceUID: String)
        /// Orbit's undo never showed and the mic is still as Orbit left it: Orbit's mute stays on record.
        case undoDidNotTake(deviceUID: String)
        case unmutedOutside(deviceUID: String)
        /// Orbit's muted mic isn't connected: its record waits in `pending` until it is back.
        case notConnected(deviceUID: String)
        /// A mic on record came back (or Orbit's write to it showed) and was put back as it was.
        case undidPending(deviceUID: String)
    }

    /// The result of a call, for the UI and the log.
    public struct Outcome: Equatable, Sendable {
        /// The input as shown: as Orbit's writes still landing will leave it.
        public var shown: MicDeviceReading?
        public var presentation: MicMutePresentation
        public var events: [Event]
    }

    /// Reads a connected device by UID (nil when it isn't connected or can't be read).
    public typealias Read = (String) -> MicDeviceReading?
    /// Writes actions to the hardware; true when every one of them took.
    public typealias Perform = ([MicMuteAction]) -> Bool

    public private(set) var state: MicMuteState
    public private(set) var writes = MicWriteConfirmation()
    public private(set) var wish: Wish?
    /// Mics whose record was set aside while a write of Orbit's to them was landing: put back once it has shown.
    private var deferredUndos: [String] = []

    public init(state: MicMuteState = MicMuteState()) {
        self.state = state
    }

    /// When to `refresh` even if no listener fires: the earliest moment a write still landing times out.
    public var nextCheck: ContinuousClock.Instant? { writes.nextDeadline }

    // MARK: Calls

    /// The user pressed mute or unmute (the Sound tab, Controls, the shortcut, the badge): written now, or once Orbit's
    /// earlier write to the mic has shown.
    public mutating func press(_ muted: Bool, input: MicDeviceReading?, now: ContinuousClock.Instant,
                               read: Read, perform: Perform) -> Outcome {
        wish = muted ? .mute : .unmute
        var outcome = refresh(input: input, now: now, read: read, perform: perform)
        if wish != nil, let uid = wish == .mute ? input?.deviceUID : state.deviceUID ?? input?.deviceUID {
            outcome.events.append(.waiting(deviceUID: uid))
        }
        return outcome
    }

    /// Undo Orbit's own mute (going inactive, the badge, a mute left on a mic that is no longer the input); a mute made
    /// outside Orbit stays, and a mute still waiting to be written is dropped.
    public mutating func release(input: MicDeviceReading?, now: ContinuousClock.Instant, read: Read, perform: Perform) -> Outcome {
        wish = .release
        return refresh(input: input, now: now, read: read, perform: perform)
    }

    /// The default input or the device list changed. While active, Orbit's mute follows the input (the old mic is put
    /// back, the new one muted); while inactive, the undo of Orbit's mute is tried again. Mics on record that are back
    /// and still as Orbit left them are put back.
    public mutating func inputChanged(active: Bool, input: MicDeviceReading?, now: ContinuousClock.Instant,
                                      read: Read, perform: Perform) -> Outcome {
        if active {
            if wish == nil, let applied = state.applied, applied.deviceUID != input?.deviceUID { wish = .mute }
        } else if state.isMuted {
            wish = .release
        }
        // The wish first: muting a mic still on record takes its record over instead of unmuting it and muting it again.
        var outcome = refresh(input: input, now: now, read: read, perform: perform)
        outcome.events += processPending(now: now, read: read, perform: perform)
        outcome.shown = input.map { writes.projected($0) }
        outcome.presentation = presentation(for: outcome.shown)
        return outcome
    }

    /// A fresh look: the input's reading, plus every other mic Orbit wrote to. Settles writes that showed or timed out,
    /// notices the user unmuting Orbit's mute outside Orbit (only from a reading that counts at face value), and carries
    /// out what waited for a mic to settle.
    public mutating func refresh(input: MicDeviceReading?, now: ContinuousClock.Instant, read: Read, perform: Perform) -> Outcome {
        var events: [Event] = []
        let inputUID = input?.deviceUID
        // Other mics: an old input put back as the input moved, a reconnected mic's undo, one waiting to be put back.
        var others: [String] = []
        for uid in writes.waitingDevices + deferredUndos where uid != inputUID && !others.contains(uid) { others.append(uid) }
        for uid in others {
            guard let reading = read(uid) else {
                // Gone. Once its writes have timed out, the mutes they were undoing wait in `pending` until it's back.
                if writes.hasTimedOut(deviceUID: uid, now: now) {
                    for record in writes.forget(deviceUID: uid) { state.takeBack(record, asInput: false) }
                    deferredUndos.removeAll { $0 == uid }
                }
                continue
            }
            let review = writes.review(reading, now: now)
            guard review.trusted else { continue }
            events += settle(review, isInput: false)
            if deferredUndos.contains(uid) { events += undoPending(uid, reading: reading, now: now, perform: perform) }
        }
        // The input.
        var inputFree = false
        if let input {
            let review = writes.review(input, now: now)
            if review.trusted {
                inputFree = true
                events += settle(review, isInput: true)
                // It no longer shows Orbit's mute: unmuted outside Orbit, or Orbit's mute never took. Either way Orbit's
                // mute is over, with nothing to undo.
                if let applied = state.applied, applied.deviceUID == input.deviceUID, !state.deviceChanged(input) {
                    events.append(review.timedOut.isEmpty ? .unmutedOutside(deviceUID: input.deviceUID)
                                                          : .muteDidNotTake(deviceUID: input.deviceUID))
                }
            }
        }
        events += carryOutWish(input: input, inputFree: inputFree, now: now, read: read, perform: perform)
        if let input, inputFree, deferredUndos.contains(input.deviceUID), !writes.isWaiting(on: input.deviceUID) {
            events += undoPending(input.deviceUID, reading: input, now: now, perform: perform)
        }
        let shown = input.map { writes.projected($0) }
        return Outcome(shown: shown, presentation: presentation(for: shown), events: events)
    }

    /// Mics on record (gone when Orbit's mute moved off them, or their undo failed): each one connected and still as
    /// Orbit left it is put back; one the user changed meanwhile is simply forgotten. One that is still taking a write
    /// of Orbit's is put back once that has shown.
    public mutating func processPending(now: ContinuousClock.Instant, read: Read, perform: Perform) -> [Event] {
        var events: [Event] = []
        for entry in state.pending {
            let uid = entry.deviceUID
            if writes.isWaiting(on: uid) {
                if !deferredUndos.contains(uid) { deferredUndos.append(uid) }
                continue
            }
            guard let reading = read(uid) else { continue }
            events += undoPending(uid, reading: reading, now: now, perform: perform)
        }
        return events
    }

    /// Orbit is quitting: Orbit's mute and every mute on record whose mic is connected are undone now, without waiting
    /// for writes still landing (the driver applies writes in order, and nothing will be read again). Whatever can't be
    /// undone stays in `state`, for the next launch.
    public mutating func quit(read: Read, perform: Perform) -> [Event] {
        var events: [Event] = []
        wish = nil
        deferredUndos = []
        if let applied = state.applied {
            if read(applied.deviceUID) != nil {
                let actions = state.restoreActions()
                if actions.isEmpty || perform(actions) {
                    state.commitRestore()
                } else {
                    events.append(.undoFailed(deviceUID: applied.deviceUID))
                }
            } else {
                state.setAside()
                events.append(.notConnected(deviceUID: applied.deviceUID))
            }
        }
        for entry in state.pending {
            guard let reading = read(entry.deviceUID) else { continue }
            // Judged on the mic as Orbit's writes still landing will leave it.
            let actions = MicMuteState.recoveryActions(for: entry, current: writes.projected(reading))
            if actions.isEmpty || perform(actions) {
                state.resolvePending(deviceUID: entry.deviceUID)
            } else {
                events.append(.undoFailed(deviceUID: entry.deviceUID))
            }
        }
        writes = MicWriteConfirmation()
        return events
    }

    /// How the input looks for the UI, `shown` as Orbit's writes in flight will leave it: a wish still waiting is shown
    /// as if done (so the next press of the shortcut toggles from it).
    public func presentation(for shown: MicDeviceReading?) -> MicMutePresentation {
        guard let wish, let shown else { return state.presentation(for: shown) }
        switch wish {
        case .mute:
            return shown.canSetMute || shown.canSetVolume ? .mutedByOrbit : .unavailable
        case .unmute, .release:
            var after = shown
            if let applied = state.applied {
                if applied.deviceUID == shown.deviceUID { after = shown.applying(MicMuteState.undo(applied)) }
            } else if wish == .unmute {
                after = shown.applying(MicMuteState.directUnmute(shown))
            }
            return MicMuteState().presentation(for: after)
        }
    }

    // MARK: Steps

    /// A mic's writes ended (shown, or timed out), and its reading counts at face value again. An undo that never
    /// showed, with the mic still exactly as Orbit left it, didn't take: Orbit's mute is still in effect there.
    private mutating func settle(_ review: MicWriteConfirmation.Review, isInput: Bool) -> [Event] {
        review.undosNotShown.compactMap { record in
            guard !MicMuteState.recoveryActions(for: record, current: review.reading).isEmpty else { return nil }
            state.takeBack(record, asInput: isInput)
            return .undoDidNotTake(deviceUID: record.deviceUID)
        }
    }

    /// Carries out the wish when the mic it needs is free of Orbit's writes; otherwise it keeps waiting.
    private mutating func carryOutWish(input: MicDeviceReading?, inputFree: Bool, now: ContinuousClock.Instant,
                                       read: Read, perform: Perform) -> [Event] {
        guard let wish else { return [] }
        switch wish {
        case .mute:
            var events: [Event] = []
            // Orbit's mute sits on another mic (the input moved): that one is put back first.
            if let applied = state.applied, applied.deviceUID != input?.deviceUID {
                events += moveAside(now: now, read: read, perform: perform)
            }
            guard let input else {
                self.wish = nil
                return events + [.cannotMute]
            }
            guard inputFree else { return events }
            self.wish = nil
            return events + muteInput(input, now: now, perform: perform)
        case .unmute, .release:
            if state.applied != nil {
                let undo = undoApplied(input: input, now: now, read: read, perform: perform)
                if !undo.waits { self.wish = nil }
                return undo.events
            }
            if wish == .unmute, let input {
                guard inputFree else { return [] }
                self.wish = nil
                return directUnmute(input, now: now, perform: perform)
            }
            self.wish = nil
            return []
        }
    }

    private mutating func muteInput(_ input: MicDeviceReading, now: ContinuousClock.Instant, perform: Perform) -> [Event] {
        guard let actions = state.mute(input) else { return [.cannotMute] }
        // A record set aside for this mic is Orbit's mute again (`mute` took it over).
        deferredUndos.removeAll { $0 == input.deviceUID }
        guard !actions.isEmpty else { return [] }
        guard perform(actions) else {
            // Put back whatever part of it took; if that fails too, the record waits in `pending`.
            let record = state.applied
            let undo = state.restoreActions()
            if undo.isEmpty || perform(undo) {
                state.commitRestore()
                writes.wrote(undo, undoing: record, at: now)
            } else {
                state.setAside()
            }
            return [.muteFailed(deviceUID: input.deviceUID)]
        }
        writes.wrote(actions, at: now)
        return []
    }

    /// Undoes Orbit's mute wherever it is. Waits while Orbit's earlier write to that mic lands. A mic that is gone keeps
    /// its record in `pending` until it is back. A failed write keeps the mute and its record (shown, and tried again by
    /// the next unmute, device change, disable or quit).
    private mutating func undoApplied(input: MicDeviceReading?, now: ContinuousClock.Instant, read: Read,
                                      perform: Perform) -> (waits: Bool, events: [Event]) {
        guard let applied = state.applied else { return (false, []) }
        let uid = applied.deviceUID
        if writes.isWaiting(on: uid) { return (true, []) }
        guard uid == input?.deviceUID || read(uid) != nil else {
            state.setAside()
            return (false, [.notConnected(deviceUID: uid)])
        }
        let actions = state.restoreActions()
        guard actions.isEmpty || perform(actions) else { return (false, [.undoFailed(deviceUID: uid)]) }
        state.commitRestore()
        writes.wrote(actions, undoing: applied, at: now)
        return (false, [])
    }

    /// Orbit's mute moves off a mic that is no longer the input: put back now, or set aside in `pending` to be put back
    /// once Orbit's write to it has shown, once it is back, or on a later device change (a failed write).
    private mutating func moveAside(now: ContinuousClock.Instant, read: Read, perform: Perform) -> [Event] {
        guard let applied = state.applied else { return [] }
        let uid = applied.deviceUID
        if writes.isWaiting(on: uid) {
            state.setAside()
            if !deferredUndos.contains(uid) { deferredUndos.append(uid) }
            return []
        }
        guard read(uid) != nil else {
            state.setAside()
            return [.notConnected(deviceUID: uid)]
        }
        let actions = state.restoreActions()
        guard actions.isEmpty || perform(actions) else {
            state.setAside()
            return [.undoFailed(deviceUID: uid)]
        }
        state.commitRestore()
        writes.wrote(actions, undoing: applied, at: now)
        return []
    }

    /// The user asked to unmute a mic muted outside Orbit.
    private mutating func directUnmute(_ input: MicDeviceReading, now: ContinuousClock.Instant, perform: Perform) -> [Event] {
        let actions = MicMuteState.directUnmute(input)
        guard !actions.isEmpty else { return [] }
        guard perform(actions) else { return [.unmuteFailed(deviceUID: input.deviceUID)] }
        writes.wrote(actions, at: now)
        return []
    }

    /// Puts back a mic on record, judged on a reading that counts at face value.
    private mutating func undoPending(_ uid: String, reading: MicDeviceReading, now: ContinuousClock.Instant,
                                      perform: Perform) -> [Event] {
        deferredUndos.removeAll { $0 == uid }
        guard let entry = state.pending.first(where: { $0.deviceUID == uid }) else { return [] }
        let actions = MicMuteState.recoveryActions(for: entry, current: reading)
        // A failed write keeps the record, tried again on the next device change and on quit.
        guard actions.isEmpty || perform(actions) else { return [.undoFailed(deviceUID: uid)] }
        state.resolvePending(deviceUID: uid)
        guard !actions.isEmpty else { return [] }
        writes.wrote(actions, undoing: entry, at: now)
        return [.undidPending(deviceUID: uid)]
    }
}
