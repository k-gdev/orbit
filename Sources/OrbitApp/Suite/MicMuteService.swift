import AppKit
import AudioToolbox
import Combine
import CoreAudio
import OrbitCore

/// The ONE mic mute in Orbit, shared by the Sound tab's mute button, the Controls tab's Mic Mute toggle,
/// the global shortcut (`MicMuteSettings.muteShortcut`, default ⌃⌥M) and the crossed-out mic badge in
/// the menu bar. Flipping any of them updates the rest through `isMuted`. It needs no permission, so it
/// works whether or not Sound is on.
///
/// `isMuted` is the input device's live state (spec §8.3): muted by Orbit, or muted outside Orbit (System
/// Settings, a headset's button; `isMutedByOrbit` tells them apart). Unmuting a mute made elsewhere is a
/// direct user action; Orbit never undoes such a mute on its own.
///
/// `FeatureRegistry` makes it active while Sound or Controls is on (`setActive`) and calls
/// `restoreOnQuit()` from `stopAll()`. While active: the shortcut is registered (hot key id `micMute`)
/// whenever an input device is available (so a Mac with no mic doesn't lose the key combo for nothing),
/// and the badge shows whenever the mic is muted. Going inactive unregisters and undoes Orbit's own mute
/// (restoring the input device's previous state). An undo that can't be written keeps the mute, the badge
/// and the record, and is retried; a muted device that is unplugged keeps its record until it is back.
@MainActor
final class MicMuteService: NSObject, ObservableObject {
    /// Whether the input device is muted right now, by Orbit or outside it. Read live.
    @Published private(set) var isMuted = false
    /// Whether Orbit's own mute is in effect (as opposed to a mute made elsewhere).
    @Published private(set) var isMutedByOrbit = false
    /// Whether there is an input device to mute. The shortcut follows it while active.
    @Published private(set) var isAvailable = false {
        didSet { if isAvailable != oldValue { updateShortcut() } }
    }

    let settings: MicMuteSettings
    private let hotKeys: HotKeyCenter?
    private let isFixture: Bool
    private var active = false
    private var badge: NSStatusItem?
    private var shortcutSubscription: AnyCancellable?
    /// Every decision of the mute (`MicMuteModel`, OrbitCore): what Orbit's mute changed, mutes still to undo on
    /// devices that went away, Orbit's writes still landing, and a press waiting for one of them.
    private var model = MicMuteModel()
    /// The one look at the device scheduled for when the earliest write still landing times out.
    private var confirmationCheck: DispatchWorkItem?
    /// Where the record survives a crash or a failed quit (nil for the fixture).
    private let restoreDefaults: UserDefaults?
    /// The record as last written to `restoreDefaults`.
    private var savedRecord: MicMuteState?
    private var didRecover = false
    /// Default-input and device-list listeners: while active, and while a record waits for its device.
    private var systemListeners: [MicHALListener] = []
    /// Mute and volume listeners on the current input device, while active (the live state).
    private var inputListeners: [MicHALListener] = []
    private var watchedInput = AudioObjectID(kAudioObjectUnknown)

    static let hotKeyID = "micMute"
    /// `UserDefaults` key of the restore record while Orbit has something to undo.
    static let pendingRestoreKey = "micMute.pendingRestore"

    /// `restoreDefaults` keeps the restore record while the mic is muted (or a mute waits to be undone), so a
    /// launch after a crash or a failed quit can finish the job (`.standard` in the app).
    init(hotKeys: HotKeyCenter, settings: MicMuteSettings, restoreDefaults: UserDefaults = .standard) {
        self.hotKeys = hotKeys
        self.settings = settings
        self.restoreDefaults = restoreDefaults
        isFixture = false
        super.init()
    }

    /// A state-only stand-in for snapshots and previews: no hardware, no hot key, no status item.
    /// `setMuted` just flips `isMuted`. `mutedElsewhere` shows a mute made outside Orbit.
    static func fixture(muted: Bool = false, available: Bool = true, mutedElsewhere: Bool = false) -> MicMuteService {
        // An absolute-path suite in the temp folder: nothing is written unless a snapshot changes the
        // shortcut, and even then never to ~/Library/Preferences.
        let path = FileManager.default.temporaryDirectory.appending(path: "orbit-fixture-\(UUID().uuidString).plist").path
        guard let defaults = UserDefaults(suiteName: path) else {
            preconditionFailure("MicMuteService.fixture: no throwaway defaults suite")
        }
        let service = MicMuteService(fixtureSettings: MicMuteSettings(defaults: defaults))
        service.isMuted = muted || mutedElsewhere
        service.isMutedByOrbit = muted && !mutedElsewhere
        service.isAvailable = available
        return service
    }

    private init(fixtureSettings: MicMuteSettings) {
        hotKeys = nil
        settings = fixtureSettings
        restoreDefaults = nil
        isFixture = true
        super.init()
    }

    /// Mutes or unmutes the current input device. Muting is Orbit's own mute (undone exactly on unmute, on
    /// going inactive and on quit); unmuting undoes Orbit's mute, or switches off a mute made elsewhere.
    /// Does nothing when no device is available; a write that fails leaves the state as it was. While an earlier
    /// write of Orbit's to the mic is still landing, the press is shown at once and written once that one has shown.
    func setMuted(_ muted: Bool) {
        // An unmute always gets through while Orbit's own mute is on record, even when that mute sits on a mic that
        // is no longer the input (and so doesn't show in `isMuted`): it must stay clearable.
        guard muted != isMuted || (!muted && model.state.isMuted) else { return }
        if isFixture {
            isMuted = muted
            isMutedByOrbit = muted
            return
        }
        note(model.press(muted, input: MicHAL.reading(for: MicHAL.defaultInputDevice()), now: .now,
                         read: MicHAL.reading(uid:), perform: MicHAL.perform).events)
        refreshLiveState()
    }

    func toggle() { setMuted(!isMuted) }

    /// On while Sound or Controls is on. Idempotent. The first call (at launch, on or off) also finishes
    /// undoing a mute that a previous run left behind (crash, or a quit whose undo couldn't be written).
    func setActive(_ on: Bool) {
        guard !isFixture else { return }
        recoverFromPreviousRunIfNeeded()
        guard on != active else { return }
        active = on
        if on {
            updateSystemListening()
            // Orbit's mute still on record from a failed undo, on a mic that is no longer the input: nobody asked to
            // mute now, so retry the undo rather than moving the mute to the current mic.
            let input = MicHAL.defaultInputDevice()
            if let uid = model.state.deviceUID, uid != MicHAL.uid(of: input) { release(input) }
            refreshLiveState()
            updateShortcut()
            shortcutSubscription = settings.$muteShortcut.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateShortcut() }
            }
        } else {
            shortcutSubscription = nil
            hotKeys?.unregister(id: Self.hotKeyID)
            // Only Orbit's own mute is undone (once a write of Orbit's still landing on the mic has shown); a mute made
            // elsewhere stays. If the undo fails, the mute, the badge and the record stay (the badge's click retries),
            // and device changes retry it.
            release(MicHAL.defaultInputDevice())
            unwatchInput()
            updateSystemListening()
            refreshLiveState()
        }
    }

    /// Orbit is quitting: put the input device back as it was and drop the badge. Whatever can't be undone now
    /// (a failed write, an unplugged device) stays on record for the next launch.
    func restoreOnQuit() {
        guard !isFixture else { return }
        shortcutSubscription = nil
        model.quit(read: MicHAL.reading(uid:), perform: MicHAL.perform).forEach(Self.log)
        saveRecord()
        confirmationCheck?.cancel()
        confirmationCheck = nil
        hotKeys?.unregister(id: Self.hotKeyID)
        removeBadge()
        unwatchInput()
        systemListeners.forEach { $0.remove() }
        systemListeners = []
        active = false
    }

    /// Registers the shortcut while active with an input device present; unregisters it otherwise.
    private func updateShortcut() {
        guard !isFixture else { return }
        guard active, isAvailable else {
            hotKeys?.unregister(id: Self.hotKeyID)
            return
        }
        if hotKeys?.register(settings.muteShortcut, id: Self.hotKeyID, action: { [weak self] in self?.toggle() }) == false {
            Log.info("mic mute shortcut \(settings.muteShortcut.display) is unavailable")
        }
    }

    // MARK: Menu bar badge

    /// While active the badge follows the live mute; Orbit's own mute keeps it even after going inactive when
    /// its undo couldn't be written (clicking it retries).
    private func updateBadge() {
        if (active && isMuted) || model.state.isMuted { showBadge() } else { removeBadge() }
        badge?.button?.toolTip = isMutedByOrbit || model.state.isMuted
            ? "Microphone muted by Orbit (\(settings.muteShortcut.display) to unmute). Click to unmute."
            : "Microphone muted outside Orbit. Click to unmute."
    }

    private func showBadge() {
        guard badge == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.target = self
        item.button?.action = #selector(badgeClicked)
        badge = item
    }

    private func removeBadge() {
        guard let badge else { return }
        NSStatusBar.system.removeStatusItem(badge)
        self.badge = nil
    }

    @objc private func badgeClicked() {
        if model.state.isMuted {
            // Orbit's own mute (possibly on a mic that is no longer the input, or left by an undo that failed while
            // inactive): undo exactly that.
            release(MicHAL.defaultInputDevice())
            refreshLiveState()
        } else {
            setMuted(false)
        }
    }

    // MARK: Hardware
    //
    // Core Audio HAL calls on the default input device (`kAudioHardwarePropertyDefaultInputDevice`). Every
    // decision lives in `MicMuteModel` (OrbitCore, tested in the service's exact call order): mute with the
    // device's mute control, or input volume 0 when it has none; remember what it was; undo exactly that; never
    // write to a mic while an earlier write of Orbit's to it is still landing (a press meanwhile is shown at once
    // and written once that write has shown or timed out); keep records for devices that went away and finish
    // them when they are back; never undo a mute the user had applied. This side only reads the hardware, writes
    // what the model asks for, and publishes the result. The record is mirrored to `restoreDefaults` so the next
    // launch can finish after a crash. No process-tap code here: this works with Sound off.

    /// Re-reads the input device's live state: Orbit's mute, a mute made elsewhere, or none; whether it can be
    /// muted at all (setting `isAvailable` re-registers the shortcut). The model also settles Orbit's writes that
    /// have shown (or timed out), notices the user unmuting Orbit's mute outside Orbit, and carries out a press that
    /// waited for a write to land. Called after every change, every listener callback and at the confirmation check.
    private func refreshLiveState() {
        guard !isFixture else { return }
        let device = MicHAL.defaultInputDevice()
        let outcome = model.refresh(input: MicHAL.reading(for: device), now: .now, read: MicHAL.reading(uid:),
                                    perform: MicHAL.perform)
        note(outcome.events)
        isAvailable = outcome.presentation != .unavailable
        isMutedByOrbit = outcome.presentation == .mutedByOrbit
        isMuted = outcome.presentation == .mutedByOrbit || outcome.presentation == .mutedElsewhere
        if active { watchInput(device) }
        updateBadge()
    }

    /// Undoes Orbit's own mute (a mute made elsewhere stays).
    private func release(_ input: AudioObjectID) {
        note(model.release(input: MicHAL.reading(for: input), now: .now, read: MicHAL.reading(uid:),
                           perform: MicHAL.perform).events)
    }

    /// After every call into the model: log what happened, keep the crash record and the system listeners in step,
    /// and schedule the next look.
    private func note(_ events: [MicMuteModel.Event]) {
        events.forEach(Self.log)
        saveRecord()
        updateSystemListening()
        scheduleConfirmationCheck()
    }

    /// One look scheduled just after the earliest write still landing times out, so a write the driver silently
    /// ignored (or a press waiting for one) is dealt with even if no listener fires. None while nothing waits.
    private func scheduleConfirmationCheck() {
        confirmationCheck?.cancel()
        confirmationCheck = nil
        guard let deadline = model.nextCheck else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.confirmationCheck = nil
            self?.refreshLiveState()
        }
        confirmationCheck = work
        let delay = max((deadline - ContinuousClock.now) / .seconds(1), 0) + 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private static func log(_ event: MicMuteModel.Event) {
        switch event {
        case .cannotMute:
            Log.info("mic mute: the input device can't be muted")
        case .waiting(let uid):
            Log.info("mic mute: \(uid) is still taking Orbit's last write; the press follows once it shows")
        case .muteFailed(let uid):
            Log.error("mic mute: muting \(uid) failed; putting it back")
        case .undoFailed(let uid):
            Log.error("mic mute: unmuting \(uid) failed; keeping the mute and its record to retry")
        case .unmuteFailed(let uid):
            Log.error("mic mute: unmuting \(uid) failed")
        case .muteDidNotTake(let uid):
            Log.info("mic mute: muting \(uid) never showed; it reads unmuted, so Orbit's mute is over")
        case .undoDidNotTake(let uid):
            Log.error("mic mute: unmuting \(uid) never showed; it is still as Orbit left it, so Orbit's mute stays on record")
        case .unmutedOutside(let uid):
            Log.info("mic mute: \(uid) was unmuted outside Orbit")
        case .notConnected(let uid):
            Log.info("mic mute: \(uid) is not connected; it will be unmuted when it is back")
        case .undidPending(let uid):
            Log.info("mic mute: \(uid) is back; undid Orbit's mute")
        }
    }

    // MARK: Listening

    /// System listeners (default input, device list) exist while active, and while a record waits for its
    /// device (so an unplugged mic is unmuted when it comes back even with Sound and Controls off).
    private func updateSystemListening() {
        let wanted = active || model.state.hasRecord
        if wanted && systemListeners.isEmpty {
            let system = AudioObjectID(kAudioObjectSystemObject)
            systemListeners = [
                MicHALListener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in self?.systemChanged() },
                MicHALListener(object: system, selector: kAudioHardwarePropertyDevices) { [weak self] in self?.systemChanged() },
            ].compactMap { $0 }
        } else if !wanted && !systemListeners.isEmpty {
            systemListeners.forEach { $0.remove() }
            systemListeners = []
        }
    }

    /// The default input or the device list changed. While active, Orbit's mute follows the input (the old mic is
    /// put back, the new one muted, each once Orbit's earlier write to it has shown); while inactive, the undo of
    /// Orbit's mute is tried again. Mics on record that are back are put back.
    private func systemChanged() {
        note(model.inputChanged(active: active, input: MicHAL.reading(for: MicHAL.defaultInputDevice()), now: .now,
                                read: MicHAL.reading(uid:), perform: MicHAL.perform).events)
        refreshLiveState()
    }

    /// Listens to the current input device's mute and volume (the live state). Re-attached when the device
    /// object changes, including a device re-enumerated under a new object ID; a device on which no listener
    /// could be installed is not retried on every refresh.
    private func watchInput(_ device: AudioObjectID) {
        guard device != watchedInput else { return }
        inputListeners.forEach { $0.remove() }
        inputListeners = []
        watchedInput = device
        guard device != kAudioObjectUnknown else { return }
        let changed: () -> Void = { [weak self] in self?.refreshLiveState() }
        inputListeners = [
            MicHALListener(object: device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, action: changed),
            MicHALListener(object: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: kAudioObjectPropertyScopeInput, action: changed),
        ].compactMap { $0 }
    }

    private func unwatchInput() {
        inputListeners.forEach { $0.remove() }
        inputListeners = []
        watchedInput = kAudioObjectUnknown
    }

    // MARK: Crash recovery

    /// Mirrors the state to `restoreDefaults` while there is anything to undo; removes it otherwise. Written only
    /// when it changed.
    private func saveRecord() {
        guard let restoreDefaults, savedRecord != model.state else { return }
        let state = model.state
        if state.hasRecord, let data = try? JSONEncoder().encode(state) {
            restoreDefaults.set(data, forKey: Self.pendingRestoreKey)
        } else {
            restoreDefaults.removeObject(forKey: Self.pendingRestoreKey)
        }
        savedRecord = state
    }

    /// Once per launch: a record still stored means the previous run crashed, was killed, or couldn't finish
    /// its undo while quitting. Everything in it becomes pending: undone now where the device is connected and
    /// still as Orbit left it, kept (with a device-list listener) until the device is back otherwise.
    private func recoverFromPreviousRunIfNeeded() {
        guard !didRecover, let restoreDefaults else { return }
        didRecover = true
        guard let data = restoreDefaults.data(forKey: Self.pendingRestoreKey) else { return }
        guard let record = try? JSONDecoder().decode(MicMuteState.self, from: data) else {
            restoreDefaults.removeObject(forKey: Self.pendingRestoreKey)
            return
        }
        model = MicMuteModel(state: .fromPreviousRun(record))
        Log.info("mic mute: finishing \(model.state.pending.count) mute(s) left by the previous run")
        note(model.processPending(now: .now, read: MicHAL.reading(uid:), perform: MicHAL.perform))
    }
}


// MARK: - Input device HAL access (mic mute only)

/// The few Core Audio calls the mic mute needs, kept here so the shared mute does not depend on the Sound
/// feature's code.
private enum MicHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func defaultInputDevice() -> AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &device) == noErr else { return kAudioObjectUnknown }
        return device
    }

    static func uid(of device: AudioObjectID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// The connected device with this UID.
    static func device(uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr, size > 0 else { return nil }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &devices) == noErr else { return nil }
        return devices.first { self.uid(of: $0) == uid }
    }

    static func isSettable(_ device: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        guard AudioObjectHasProperty(device, &addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static func read<T>(_ device: AudioObjectID, _ addr: AudioObjectPropertyAddress, as: T.Type, zero: T) -> T? {
        var addr = addr
        guard AudioObjectHasProperty(device, &addr) else { return nil }
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(device, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    static func write<T>(_ device: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> Bool {
        var addr = addr
        var value = value
        let status = withUnsafePointer(to: &value) { AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
        return status == noErr
    }

    static func inputChannelCount(_ device: AudioObjectID) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// The elements carrying `selector` on the input side: the main element when it is settable, otherwise
    /// every settable channel.
    static func settableElements(_ device: AudioObjectID, _ selector: AudioObjectPropertySelector) -> [AudioObjectPropertyElement] {
        if isSettable(device, address(selector, kAudioObjectPropertyScopeInput)) { return [kAudioObjectPropertyElementMain] }
        let channels = inputChannelCount(device)
        guard channels > 0 else { return [] }
        return (1...UInt32(channels)).filter { isSettable(device, address(selector, kAudioObjectPropertyScopeInput, $0)) }
    }

    /// The input volume control to use: the virtual main volume, else the device's own volume (main element
    /// or channels).
    static func volumeTargets(_ device: AudioObjectID) -> [AudioObjectPropertyAddress] {
        let virtual = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput)
        if isSettable(device, virtual) { return [virtual] }
        return settableElements(device, kAudioDevicePropertyVolumeScalar)
            .map { address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, $0) }
    }

    /// The connected device with this UID, read (nil when it isn't connected).
    static func reading(uid: String) -> MicDeviceReading? {
        device(uid: uid).flatMap { reading(for: $0) }
    }

    /// Applies HAL changes; true when every one of them took.
    static func perform(_ actions: [MicMuteAction]) -> Bool {
        var ok = true
        for action in actions {
            switch action {
            case .setMute(let uid, let muted):
                guard let device = device(uid: uid), setMute(device, muted) else { ok = false; continue }
            case .setVolume(let uid, let volume):
                guard let device = device(uid: uid), setVolume(device, volume) else { ok = false; continue }
            }
        }
        return ok
    }

    static func reading(for device: AudioObjectID) -> MicDeviceReading? {
        guard device != kAudioObjectUnknown, let uid = uid(of: device) else { return nil }
        let muteElements = settableElements(device, kAudioDevicePropertyMute)
        let muted = muteElements.first.flatMap {
            read(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, $0), as: UInt32.self, zero: 0)
        }
        let volumes = volumeTargets(device)
        let volume = volumes.first.flatMap { read(device, $0, as: Float32.self, zero: 0) }
        return MicDeviceReading(deviceUID: uid, canSetMute: !muteElements.isEmpty, isMuted: (muted ?? 0) != 0,
                                canSetVolume: !volumes.isEmpty, volume: volume)
    }

    static func setMute(_ device: AudioObjectID, _ muted: Bool) -> Bool {
        let elements = settableElements(device, kAudioDevicePropertyMute)
        guard !elements.isEmpty else { return false }
        return elements.map { write(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeInput, $0), UInt32(muted ? 1 : 0)) }
            .allSatisfy { $0 }
    }

    static func setVolume(_ device: AudioObjectID, _ volume: Float) -> Bool {
        let targets = volumeTargets(device)
        guard !targets.isEmpty else { return false }
        return targets.map { write(device, $0, Float32(min(max(volume, 0), 1))) }.allSatisfy { $0 }
    }
}

/// One Core Audio property listener (block-based, delivered on the main queue), removed with `remove()`.
private final class MicHALListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    /// Nil when the object doesn't have the property or the HAL refuses the listener.
    init?(object: AudioObjectID, selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          action: @escaping @MainActor () -> Void) {
        self.object = object
        address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        block = { _, _ in MainActor.assumeIsolated { action() } }
        guard AudioObjectHasProperty(object, &address),
              AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main, block) == noErr else { return nil }
        installed = true
    }

    func remove() {
        guard installed else { return }
        installed = false
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit { remove() }
}
