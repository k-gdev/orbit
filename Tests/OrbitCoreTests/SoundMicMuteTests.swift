import Foundation
import Testing
@testable import OrbitCore

/// Orbit's shared mic mute on simulated hardware, driven in `MicMuteService`'s real call order:
/// - a press is `model.press` followed by the post-write `refreshLiveState` (`model.refresh` with a fresh reading);
/// - a write shows in readings only `latency` after it was made (Core Audio may apply it asynchronously), or never
///   for a device whose driver ignores it;
/// - every change on the current input fires its listener (`refreshLiveState`); changes on other mics fire nothing
///   (the service only listens to the input);
/// - the confirmation check (`refreshLiveState`) runs 50 ms after `model.nextCheck`;
/// - an input switch is `model.inputChanged` followed by `refreshLiveState`.
final class MicRig {
    var model = MicMuteModel()
    private(set) var devices: [String: MicDeviceReading] = [:]
    private(set) var input: String?
    private(set) var now = ContinuousClock.now
    let start: ContinuousClock.Instant
    var latency: Duration = .milliseconds(30)
    /// Devices whose driver accepts writes but never applies them.
    var ignoring: Set<String> = []
    /// Every write Orbit made, in order.
    private(set) var written: [MicMuteAction] = []
    private(set) var events: [MicMuteModel.Event] = []
    private(set) var presentation: MicMutePresentation = .unavailable
    private(set) var active = true
    /// Changes still to reach the hardware: Orbit's writes landing, and changes made outside Orbit.
    private var changes: [(at: ContinuousClock.Instant, action: MicMuteAction)] = []
    private var check: ContinuousClock.Instant?

    init(_ readings: MicDeviceReading..., input: String?) {
        for reading in readings { devices[reading.deviceUID] = reading }
        self.input = input
        start = now
        refresh()
    }

    var isMuted: Bool { presentation == .mutedByOrbit || presentation == .mutedElsewhere }
    /// Seconds since the rig started, for readable expectations.
    var elapsed: Double { (now - start) / .seconds(1) }

    private func read(_ uid: String) -> MicDeviceReading? { devices[uid] }

    private func perform(_ actions: [MicMuteAction]) -> Bool {
        for action in actions {
            written.append(action)
            if !ignoring.contains(action.deviceUID) { changes.append((now + latency, action)) }
        }
        return true
    }

    private func handle(_ outcome: MicMuteModel.Outcome) {
        events += outcome.events
        presentation = outcome.presentation
        check = model.nextCheck.map { $0 + .milliseconds(50) }
    }

    /// `MicMuteService.setMuted` (with its guard), then its post-write `refreshLiveState`.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted || (!muted && model.state.isMuted) else { return }
        handle(model.press(muted, input: input.flatMap(read), now: now, read: read, perform: perform))
        refresh()
    }

    /// ⌃⌥M.
    func toggle() { setMuted(!isMuted) }

    /// `refreshLiveState`: a listener callback, or the confirmation check.
    func refresh() {
        handle(model.refresh(input: input.flatMap(read), now: now, read: read, perform: perform))
    }

    /// The default input switched (`systemChanged`).
    func switchInput(to uid: String?) {
        input = uid
        handle(model.inputChanged(active: active, input: input.flatMap(read), now: now, read: read, perform: perform))
        refresh()
    }

    /// Sound and Controls are turned off (`setActive(false)`).
    func deactivate() {
        active = false
        handle(model.release(input: input.flatMap(read), now: now, read: read, perform: perform))
        refresh()
    }

    /// A change made outside Orbit (System Settings, the headset's button), reaching the device `after` from now.
    func outside(_ action: MicMuteAction, after delay: Duration = .zero) {
        changes.append((now + delay, action))
        if delay == .zero { advance(by: .zero) }
    }

    /// Time passes: changes reach the hardware (while active, the input's listener fires once per moment something
    /// changed on it; inactive, the service doesn't listen to it), and the confirmation check runs when due.
    func advance(by duration: Duration) {
        let end = now + duration
        while true {
            let due = (changes.map(\.at) + [check].compactMap { $0 }).filter { $0 <= end }.min()
            guard let due else { break }
            now = due
            let landing = changes.filter { $0.at <= due }
            changes.removeAll { $0.at <= due }
            for change in landing { devices[change.action.deviceUID] = devices[change.action.deviceUID]?.applying([change.action]) }
            if active, let input, landing.contains(where: { $0.action.deviceUID == input }) {
                refresh()
            } else if let check, check <= due {
                self.check = nil
                refresh()
            }
        }
        now = end
    }
}

extension SoundTests.MicMuteStateTests {
    private static let usb = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
    private static let builtIn = MicDeviceReading(deviceUID: "BuiltIn", canSetMute: true, isMuted: false, canSetVolume: true, volume: 1)

    /// G1 (a): ⌃⌥M twice in quick succession after Orbit's mute, the second press within the write latency of Orbit's
    /// unmute, while the device still reads muted. No write goes to the mic while the unmute lands; the press is shown
    /// at once, and the mute is written once the unmute has shown. The mic ends muted, by Orbit, and the next unmute
    /// (or disabling) really unmutes it.
    @Test func quickMuteAfterOwnUnmuteWaitsForIt() {
        let rig = MicRig(headset, input: "Headset")
        rig.toggle()
        #expect(rig.written == [.setMute(deviceUID: "Headset", muted: true)])
        #expect(rig.presentation == .mutedByOrbit)
        rig.advance(by: .milliseconds(40))                            // the mute lands
        #expect(rig.devices["Headset"]?.isMuted == true)
        #expect(!rig.model.writes.isWaiting)

        rig.toggle()                                                   // unmute: written, still reads muted
        #expect(rig.written.last == .setMute(deviceUID: "Headset", muted: false))
        #expect(rig.presentation == .unmuted)
        rig.advance(by: .milliseconds(5))
        rig.toggle()                                                   // the quick second press: mute
        #expect(rig.written.count == 2)                                // nothing written while the unmute lands
        #expect(rig.presentation == .mutedByOrbit)                     // shown at once
        #expect(rig.events.contains(.waiting(deviceUID: "Headset")))
        rig.advance(by: .milliseconds(30))                             // the unmute lands: now the mute is written
        #expect(rig.written == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: false),
                                .setMute(deviceUID: "Headset", muted: true)])
        rig.advance(by: .seconds(3))
        #expect(rig.devices["Headset"]?.isMuted == true)
        #expect(rig.presentation == .mutedByOrbit)
        #expect(rig.model.state.applied?.method == .muteFlag(wasMuted: false))
        #expect(!rig.events.contains(.unmutedOutside(deviceUID: "Headset")))
        #expect(rig.written.count == 3)                                // nothing more, no retry

        rig.deactivate()                                               // disabling undoes it
        rig.advance(by: .seconds(3))
        #expect(rig.devices["Headset"]?.isMuted == false)
        #expect(!rig.model.state.hasRecord)

        // Four presses inside one write's latency: they only move the wish; the last (unmute) needs no write at all.
        let quick = MicRig(headset, input: "Headset")
        quick.toggle()
        quick.advance(by: .milliseconds(40))
        quick.toggle()
        quick.toggle()
        quick.toggle()
        #expect(quick.presentation == .unmuted)
        quick.advance(by: .seconds(3))
        #expect(quick.written == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: false)])
        #expect(quick.devices["Headset"]?.isMuted == false)
        #expect(quick.presentation == .unmuted && !quick.model.state.hasRecord)
    }

    /// G1 (b): the same quick double press on a mic without a mute control (input volume 0 as the mute). The 0.62 restore
    /// lands before the second mute is written, so that mute records 0.62 (not the stale 0) and the mic is never left
    /// at 0 while shown unmuted.
    @Test func quickVolumeMuteAfterOwnRestoreWaitsForIt() {
        let rig = MicRig(Self.usb, input: "USB")
        rig.toggle()
        rig.advance(by: .milliseconds(40))
        #expect(rig.devices["USB"]?.volume == 0)
        rig.toggle()                                                   // restore 0.62, still reads 0
        #expect(rig.written.last == .setVolume(deviceUID: "USB", volume: 0.62))
        #expect(rig.presentation == .unmuted)
        rig.advance(by: .milliseconds(5))
        rig.toggle()                                                   // the quick second press
        #expect(rig.written.count == 2)
        #expect(rig.presentation == .mutedByOrbit)
        rig.advance(by: .milliseconds(30))                             // 0.62 lands; then 0 is written
        #expect(rig.written.last == .setVolume(deviceUID: "USB", volume: 0))
        #expect(rig.model.state.applied?.method == .volume(previous: 0.62))
        rig.advance(by: .seconds(3))
        #expect(rig.devices["USB"]?.volume == 0)
        #expect(rig.presentation == .mutedByOrbit)
        #expect(rig.written.count == 3)
        rig.toggle()                                                   // the next unmute brings 0.62 back
        rig.advance(by: .seconds(3))
        #expect(rig.devices["USB"]?.volume == 0.62)
        #expect(rig.presentation == .unmuted && !rig.model.state.hasRecord)
    }

    /// G1 (c): muted on the headset, macOS switches the input to the built-in mic (headset put back, built-in muted) and
    /// straight back while both writes are still landing. Neither mic gets a second write before its first has shown:
    /// the headset is muted again once its put-back has shown, the built-in mic put back once its mute has shown. The
    /// headset ends muted by Orbit (the next unmute really unmutes it), the built-in mic unmuted, nothing left on record.
    @Test func inputFlipBackWhileMutedWaitsForBothMics() {
        let rig = MicRig(headset, Self.builtIn, input: "Headset")
        rig.toggle()
        rig.advance(by: .milliseconds(40))
        rig.switchInput(to: "BuiltIn")
        #expect(rig.written == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: false),
                                .setMute(deviceUID: "BuiltIn", muted: true)])
        rig.advance(by: .milliseconds(5))
        rig.switchInput(to: "Headset")                                 // the headset still reads muted
        #expect(rig.written.count == 3)                                // no write to either mic yet
        #expect(rig.presentation == .mutedByOrbit)
        #expect(!rig.events.contains(.unmutedOutside(deviceUID: "Headset")))
        rig.advance(by: .seconds(3))
        #expect(rig.written.suffix(2).sorted { "\($0)" < "\($1)" } == [.setMute(deviceUID: "BuiltIn", muted: false),
                                                                       .setMute(deviceUID: "Headset", muted: true)])
        #expect(rig.written.count == 5)
        #expect(rig.devices["Headset"]?.isMuted == true)
        #expect(rig.devices["BuiltIn"]?.isMuted == false)
        #expect(rig.presentation == .mutedByOrbit)
        #expect(rig.model.state.applied == MicMuteState.Applied(deviceUID: "Headset", method: .muteFlag(wasMuted: false)))
        #expect(rig.model.state.pending.isEmpty)
        #expect(!rig.events.contains(.unmutedOutside(deviceUID: "Headset")))
        rig.toggle()
        rig.advance(by: .seconds(3))
        #expect(rig.devices["Headset"]?.isMuted == false)
        #expect(!rig.model.state.hasRecord)
    }

    /// G1 (d): the user unmutes outside Orbit while Orbit's mute is still landing. A reading taken meanwhile never
    /// concludes "unmuted outside Orbit"; the unmute is seen once Orbit's write has shown, or has timed out.
    @Test func outsideUnmuteDuringOwnWriteIsSeenAfterIt() {
        // The mute lands and the user unmutes in the same moment: no reading ever shows the mute. Orbit keeps its mute
        // (shown muted) until the write times out; then the mic counts as it reads: unmuted, nothing to undo.
        let rig = MicRig(headset, input: "Headset")
        rig.toggle()
        rig.outside(.setMute(deviceUID: "Headset", muted: false), after: rig.latency)
        rig.advance(by: .milliseconds(40))
        #expect(rig.devices["Headset"]?.isMuted == false)
        #expect(rig.model.state.isMuted)                               // not concluded from a reading taken in flight
        #expect(rig.presentation == .mutedByOrbit)
        rig.advance(by: .seconds(3))
        #expect(!rig.model.state.isMuted)
        #expect(rig.presentation == .unmuted)
        #expect(rig.events.contains(.muteDidNotTake(deviceUID: "Headset")))
        #expect(rig.written == [.setMute(deviceUID: "Headset", muted: true)])

        // The mute shows first, then the user unmutes: seen at once.
        let later = MicRig(headset, input: "Headset")
        later.toggle()
        later.advance(by: .milliseconds(40))
        later.outside(.setMute(deviceUID: "Headset", muted: false))
        #expect(later.events.contains(.unmutedOutside(deviceUID: "Headset")))
        #expect(!later.model.state.isMuted && later.presentation == .unmuted)

        // With a press waiting: mute, unmute and mute again inside the mute's latency, while the user unmutes outside as
        // the mute lands. The last press (mute) is carried out once the first mute is found not to have taken.
        let waiting = MicRig(headset, input: "Headset")
        waiting.toggle()
        waiting.toggle()
        waiting.toggle()
        #expect(waiting.written == [.setMute(deviceUID: "Headset", muted: true)])
        waiting.outside(.setMute(deviceUID: "Headset", muted: false), after: waiting.latency)
        waiting.advance(by: .seconds(5))
        #expect(waiting.written == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: true)])
        #expect(waiting.devices["Headset"]?.isMuted == true)
        #expect(waiting.presentation == .mutedByOrbit && waiting.model.state.isMuted)
    }

    /// G1 (e): a write the driver accepts but never applies. Once it times out the mic counts as it reads (the UI is
    /// honest), and Orbit never retries on its own.
    @Test func ignoredWritesTimeOutHonestly() {
        // An ignored mute: shown muted while it may still land, then unmuted; Orbit's mute is over.
        let rig = MicRig(headset, input: "Headset")
        rig.ignoring = ["Headset"]
        rig.toggle()
        #expect(rig.presentation == .mutedByOrbit)
        rig.advance(by: .seconds(1))
        #expect(rig.presentation == .mutedByOrbit)
        rig.advance(by: .seconds(2))
        #expect(rig.presentation == .unmuted)
        #expect(!rig.model.state.hasRecord)
        #expect(rig.events.contains(.muteDidNotTake(deviceUID: "Headset")))
        rig.advance(by: .seconds(30))
        #expect(rig.written.count == 1)                                // no retry
        #expect(rig.model.nextCheck == nil)

        // An ignored unmute: the mic is still as Orbit left it, so Orbit's mute is still in effect and stays on record
        // (shown muted, undone by the next unmute, on disable and on quit). Not retried on its own.
        let undo = MicRig(headset, input: "Headset")
        undo.toggle()
        undo.advance(by: .milliseconds(40))
        undo.ignoring = ["Headset"]
        undo.toggle()
        #expect(undo.presentation == .unmuted)                         // while it may still land
        undo.advance(by: .seconds(3))
        #expect(undo.devices["Headset"]?.isMuted == true)
        #expect(undo.presentation == .mutedByOrbit)                    // not "Muted outside Orbit"
        #expect(undo.model.state.applied?.method == .muteFlag(wasMuted: false))
        #expect(undo.events.contains(.undoDidNotTake(deviceUID: "Headset")))
        undo.advance(by: .seconds(30))
        #expect(undo.written.count == 2)
        undo.ignoring = []
        undo.toggle()                                                  // the user's next press does unmute
        undo.advance(by: .seconds(3))
        #expect(undo.devices["Headset"]?.isMuted == false && undo.presentation == .unmuted)

        // The volume fallback: an ignored restore leaves the mic at 0. Shown muted by Orbit (not "on" at 0), and the
        // next press restores 0.62 (it doesn't record 0 as the previous volume and get stuck there).
        let volume = MicRig(Self.usb, input: "USB")
        volume.toggle()
        volume.advance(by: .milliseconds(40))
        volume.ignoring = ["USB"]
        volume.toggle()
        volume.advance(by: .seconds(3))
        #expect(volume.devices["USB"]?.volume == 0)
        #expect(volume.presentation == .mutedByOrbit)
        #expect(volume.model.state.applied?.method == .volume(previous: 0.62))
        volume.ignoring = []
        volume.toggle()
        volume.advance(by: .seconds(3))
        #expect(volume.written.last == .setVolume(deviceUID: "USB", volume: 0.62))
        #expect(volume.devices["USB"]?.volume == 0.62 && volume.presentation == .unmuted)
    }

    /// The reverse of (a): unmute pressed while Orbit's mute is still landing. The unmute waits for the mute to show,
    /// then undoes it; the mic doesn't end muted with Orbit's record gone. Disabling in that window works the same way,
    /// and quitting doesn't wait at all.
    @Test func unmuteDuringOwnMuteWaitsForIt() {
        let rig = MicRig(headset, input: "Headset")
        rig.toggle()
        rig.advance(by: .milliseconds(5))
        rig.toggle()
        #expect(rig.written.count == 1)
        #expect(rig.presentation == .unmuted)
        rig.advance(by: .seconds(3))
        #expect(rig.written == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: false)])
        #expect(rig.devices["Headset"]?.isMuted == false)
        #expect(rig.presentation == .unmuted && !rig.model.state.hasRecord)

        let disabled = MicRig(headset, input: "Headset")
        disabled.toggle()
        disabled.deactivate()
        #expect(disabled.written.count == 1)
        #expect(disabled.model.state.isMuted)                          // the badge stays until the undo is written
        disabled.advance(by: .seconds(3))
        #expect(disabled.devices["Headset"]?.isMuted == false)
        #expect(!disabled.model.state.hasRecord)

        var quitting = MicMuteModel()
        let device = headset
        var writes: [MicMuteAction] = []
        let now = ContinuousClock.now
        _ = quitting.press(true, input: device, now: now, read: { _ in device }, perform: { writes += $0; return true })
        _ = quitting.quit(read: { _ in device }, perform: { writes += $0; return true })
        #expect(writes == [.setMute(deviceUID: "Headset", muted: true), .setMute(deviceUID: "Headset", muted: false)])
        #expect(!quitting.state.hasRecord && !quitting.writes.isWaiting)
        #expect(quitting.presentation(for: headset) == .unmuted)
    }

    /// The round-4 reviewer's two proof scripts (`f1check/main.swift`, `f1check/flipback/main.swift`), replayed with the
    /// same readings at the same moments through the model, including the service's post-write refresh read.
    @Test func reviewerScriptsReplayed() {
        let t0 = ContinuousClock.now
        func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
        var muted = headset
        muted.isMuted = true
        var log: [MicMuteAction] = []
        let perform: MicMuteModel.Perform = { log += $0; return true }

        // Mute flag: mute at 0 (landed by 0.05), unmute at 1, second mute at 1.02 while it still reads muted, the
        // post-write refresh at 1.021, the unmute landing at 1.05, the mute landing at 1.08.
        var model = MicMuteModel()
        _ = model.press(true, input: headset, now: t0, read: { _ in nil }, perform: perform)
        _ = model.refresh(input: muted, now: at(0.05), read: { _ in nil }, perform: perform)
        _ = model.press(false, input: muted, now: at(1), read: { _ in nil }, perform: perform)
        _ = model.refresh(input: muted, now: at(1.01), read: { _ in nil }, perform: perform)
        let second = model.press(true, input: muted, now: at(1.02), read: { _ in nil }, perform: perform)
        let refresh = model.refresh(input: muted, now: at(1.021), read: { _ in nil }, perform: perform)
        #expect(log.count == 2)                                        // the second press writes nothing yet
        #expect(second.presentation == .mutedByOrbit && refresh.presentation == .mutedByOrbit)
        let landed = model.refresh(input: headset, now: at(1.05), read: { _ in nil }, perform: perform)
        #expect(!landed.events.contains(.unmutedOutside(deviceUID: "Headset")))
        #expect(log.last == .setMute(deviceUID: "Headset", muted: true))   // written once the unmute showed
        let final = model.refresh(input: muted, now: at(1.08), read: { _ in nil }, perform: perform)
        #expect(final.presentation == .mutedByOrbit)
        #expect(model.state.restoreActions() == [.setMute(deviceUID: "Headset", muted: false)])

        // Volume fallback, same moments: the second mute records 0.62, and the next unmute restores it.
        let usb = Self.usb
        var zero = usb
        zero.volume = 0
        log = []
        var volume = MicMuteModel()
        _ = volume.press(true, input: usb, now: t0, read: { _ in nil }, perform: perform)
        _ = volume.refresh(input: zero, now: at(0.05), read: { _ in nil }, perform: perform)
        _ = volume.press(false, input: zero, now: at(1), read: { _ in nil }, perform: perform)
        _ = volume.press(true, input: zero, now: at(1.02), read: { _ in nil }, perform: perform)
        _ = volume.refresh(input: zero, now: at(1.021), read: { _ in nil }, perform: perform)
        let raised = volume.refresh(input: usb, now: at(1.05), read: { _ in nil }, perform: perform)
        #expect(!raised.events.contains(.unmutedOutside(deviceUID: "USB")))
        let dropped = volume.refresh(input: zero, now: at(1.08), read: { _ in nil }, perform: perform)
        #expect(dropped.presentation == .mutedByOrbit && volume.state.isMuted)
        #expect(volume.state.applied?.method == .volume(previous: 0.62))
        _ = volume.press(false, input: zero, now: at(5), read: { _ in nil }, perform: perform)
        #expect(log.last == .setVolume(deviceUID: "USB", volume: 0.62))

        // Flip-back: Orbit's mute moves Headset → BuiltIn (headset put back) and straight back at 0.03, while the headset
        // still reads muted; the refresh at 0.031; the put-back landing at 0.06.
        let builtIn = Self.builtIn
        var mutedBuiltIn = builtIn
        mutedBuiltIn.isMuted = true
        log = []
        var flip = MicMuteModel()
        _ = flip.press(true, input: headset, now: t0 - .seconds(1), read: { _ in nil }, perform: perform)
        _ = flip.refresh(input: muted, now: t0 - .milliseconds(900), read: { _ in nil }, perform: perform)
        _ = flip.inputChanged(active: true, input: builtIn, now: t0, read: { $0 == "Headset" ? muted : builtIn }, perform: perform)
        let back = flip.inputChanged(active: true, input: muted, now: at(0.03), read: { $0 == "Headset" ? muted : builtIn },
                                     perform: perform)
        let backRefresh = flip.refresh(input: muted, now: at(0.031), read: { $0 == "Headset" ? muted : builtIn }, perform: perform)
        #expect(log.count == 3)                                        // nothing written to either mic yet
        #expect(back.presentation == .mutedByOrbit && backRefresh.presentation == .mutedByOrbit)
        let flipLanded = flip.refresh(input: headset, now: at(0.06), read: { $0 == "Headset" ? headset : mutedBuiltIn },
                                      perform: perform)
        #expect(!flipLanded.events.contains(.unmutedOutside(deviceUID: "Headset")))
        #expect(log.suffix(2).contains(.setMute(deviceUID: "Headset", muted: true)))
        #expect(log.suffix(2).contains(.setMute(deviceUID: "BuiltIn", muted: false)))
        #expect(flip.state.isMuted && flip.state.deviceUID == "Headset")
        #expect(flip.state.pending.isEmpty)
    }
}

/// A mic that takes Core Audio's mute and input volume, reads them back, and keeps sending sound anyway (the Arctis
/// Nova 5, found on hardware): Orbit must treat it as a mic it can't mute, never show it muted, and never leave
/// Orbit's mute behind on the mic it came from.
extension SoundTests.MicMuteStateTests {
    private static let arctisModel = "SteelSeries Arctis Nova 5:1038:2232"
    private static let arctis = MicDeviceReading(deviceUID: "Arctis", canSetMute: true, isMuted: false, canSetVolume: true, volume: 1)

    @Test func arctisNova5IsKnownToIgnoreMute() {
        #expect(MicsIgnoringMute.contains(modelUID: Self.arctisModel))
        #expect(MicsIgnoringMute.contains(modelUID: "STEELSERIES ARCTIS NOVA 5:1038:2232"))
        #expect(!MicsIgnoringMute.contains(modelUID: "Digital Mic"))
        #expect(!MicsIgnoringMute.contains(modelUID: "Some Headset:1038:2253"))   // untested sibling
        #expect(!MicsIgnoringMute.contains(modelUID: "1038:2232"))                // no name part: not a USB model UID
        #expect(!MicsIgnoringMute.contains(modelUID: nil))
    }

    @Test func aMicIgnoringMuteOffersNoControls() {
        let usable = Self.arctis.usable(modelUID: Self.arctisModel)
        #expect(!usable.canSetMute && !usable.canSetVolume)
        #expect(usable.deviceUID == "Arctis" && usable.volume == 1 && !usable.isMuted)   // still reads as it is
        #expect(Self.builtIn.usable(modelUID: "Digital Mic") == Self.builtIn)
    }

    @Test func muteOnAMicIgnoringMuteWritesNothingAndIsNotShownMuted() {
        let rig = MicRig(Self.arctis.usable(modelUID: Self.arctisModel), input: "Arctis")
        #expect(rig.presentation == .unavailable)
        rig.toggle()
        rig.advance(by: .seconds(3))
        #expect(rig.written.isEmpty)
        #expect(rig.presentation == .unavailable)
        #expect(rig.events.contains(.cannotMute))
        #expect(!rig.model.state.hasRecord)
    }

    @Test func switchingToAMicIgnoringMutePutsTheOldMicBack() {
        let rig = MicRig(Self.builtIn, Self.arctis.usable(modelUID: Self.arctisModel), input: "BuiltIn")
        rig.toggle()
        rig.advance(by: .milliseconds(100))
        #expect(rig.presentation == .mutedByOrbit)
        rig.switchInput(to: "Arctis")
        rig.advance(by: .seconds(3))
        #expect(rig.presentation == .unavailable)                     // not "Muted": the headset is live
        #expect(rig.devices["BuiltIn"]?.isMuted == false)
        #expect(!rig.written.contains { $0.deviceUID == "Arctis" })
        #expect(!rig.model.state.hasRecord)
    }
}
