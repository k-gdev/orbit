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
/// `FeatureRegistry` makes it active while Sound or Controls is on (`setActive`) and calls
/// `restoreOnQuit()` from `stopAll()`. While active: the shortcut is registered (hot key id `micMute`)
/// whenever an input device is available (so a Mac with no mic doesn't lose the key combo for nothing),
/// and the badge shows whenever the mic is muted. Going inactive unregisters, removes the badge, and
/// unmutes (restoring the input device's previous state) if Orbit muted it.
@MainActor
final class MicMuteService: NSObject, ObservableObject {
    /// Whether the input device is muted (by Orbit).
    @Published private(set) var isMuted = false
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
    /// What Orbit's mute changed on the input device, so exactly that is undone.
    private var state = MicMuteState()
    /// Where the restore record survives a crash (nil for the fixture).
    private let restoreDefaults: UserDefaults?
    private var didRecover = false
    /// Default-input and device-list listeners, while active.
    private var systemListeners: [MicHALListener] = []
    /// Mute and volume listeners on the device Orbit muted, while muted.
    private var deviceListeners: [MicHALListener] = []

    static let hotKeyID = "micMute"
    /// `UserDefaults` key of the restore record while Orbit's mute is in effect.
    static let pendingRestoreKey = "micMute.pendingRestore"

    /// `restoreDefaults` keeps the restore record while the mic is muted, so a launch after a crash can
    /// undo the mute (`.standard` in the app).
    init(hotKeys: HotKeyCenter, settings: MicMuteSettings, restoreDefaults: UserDefaults = .standard) {
        self.hotKeys = hotKeys
        self.settings = settings
        self.restoreDefaults = restoreDefaults
        isFixture = false
        super.init()
    }

    /// A state-only stand-in for snapshots and previews: no hardware, no hot key, no status item.
    /// `setMuted` just flips `isMuted`.
    static func fixture(muted: Bool = false, available: Bool = true) -> MicMuteService {
        // An absolute-path suite in the temp folder: nothing is written unless a snapshot changes the
        // shortcut, and even then never to ~/Library/Preferences.
        let path = FileManager.default.temporaryDirectory.appending(path: "orbit-fixture-\(UUID().uuidString).plist").path
        guard let defaults = UserDefaults(suiteName: path) else {
            preconditionFailure("MicMuteService.fixture: no throwaway defaults suite")
        }
        let service = MicMuteService(fixtureSettings: MicMuteSettings(defaults: defaults))
        service.isMuted = muted
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

    /// Mutes or unmutes the current input device. Does nothing when no device is available.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        if isFixture { isMuted = muted; return }
        guard applyHardwareMute(muted) else { return }
        isMuted = muted
        updateBadge()
    }

    func toggle() { setMuted(!isMuted) }

    /// On while Sound or Controls is on. Idempotent. The first call (at launch, on or off) also undoes a
    /// mute that a previous run left behind by crashing.
    func setActive(_ on: Bool) {
        guard !isFixture else { return }
        recoverFromPreviousRunIfNeeded()
        guard on != active else { return }
        active = on
        if on {
            startListening()
            refreshAvailability()
            updateShortcut()
            shortcutSubscription = settings.$muteShortcut.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateShortcut() }
            }
            updateBadge()
        } else {
            shortcutSubscription = nil
            hotKeys?.unregister(id: Self.hotKeyID)
            if isMuted { setMuted(false) }
            removeBadge()
            stopListening()
        }
    }

    /// Orbit is quitting: put the input device back as it was and drop the badge.
    func restoreOnQuit() {
        guard !isFixture else { return }
        if isMuted {
            restoreHardware()
            isMuted = false
        }
        hotKeys?.unregister(id: Self.hotKeyID)
        removeBadge()
        stopListening()
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

    private func updateBadge() {
        if active && isMuted { showBadge() } else { removeBadge() }
    }

    private func showBadge() {
        guard badge == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Microphone muted by Orbit (\(settings.muteShortcut.display) to unmute). Click to unmute."
        item.button?.target = self
        item.button?.action = #selector(badgeClicked)
        badge = item
    }

    private func removeBadge() {
        guard let badge else { return }
        NSStatusBar.system.removeStatusItem(badge)
        self.badge = nil
    }

    @objc private func badgeClicked() { setMuted(false) }

    // MARK: Hardware
    //
    // Core Audio HAL calls on the default input device (`kAudioHardwarePropertyDefaultInputDevice`). The
    // decisions live in `MicMuteState` (OrbitCore, tested): mute with the device's mute control, or input
    // volume 0 when it has none; remember what it was; restore exactly that on unmute, on going inactive
    // and on quit; never undo a mute the user had applied. While muted, the record is also kept in
    // `restoreDefaults` so the next launch can undo it after a crash. No process-tap code here: this works
    // with Sound off.

    /// Re-reads whether there is an input device Orbit can mute (setting `isAvailable` re-registers the
    /// shortcut). Called on activation and whenever the default input or the device list changes.
    private func refreshAvailability() {
        let device = MicHAL.defaultInputDevice()
        isAvailable = MicHAL.reading(for: device).map { $0.canSetMute || $0.canSetVolume } ?? false
    }

    /// Mutes (remembering the previous state) or restores the input device. Returns whether it worked.
    private func applyHardwareMute(_ muted: Bool) -> Bool {
        guard muted else {
            restoreHardware()
            return true
        }
        let device = MicHAL.defaultInputDevice()
        guard let reading = MicHAL.reading(for: device), let actions = state.mute(reading) else {
            Log.info("mic mute: the input device can't be muted")
            return false
        }
        guard perform(actions) else {
            Log.error("mic mute: muting \(reading.deviceUID) failed; putting it back")
            _ = perform(state.restore())
            return false
        }
        savePendingRestore()
        watchMutedDevice(device)
        return true
    }

    /// Restores the input device's state from before Orbit muted it (nothing when Orbit didn't mute it).
    private func restoreHardware() {
        let actions = state.restore()
        if !perform(actions) { Log.error("mic mute: restoring the input device failed (it may be gone)") }
        clearPendingRestore()
        unwatchMutedDevice()
    }

    /// Applies HAL changes; true when every one of them took.
    private func perform(_ actions: [MicMuteAction]) -> Bool {
        var ok = true
        for action in actions {
            switch action {
            case .setMute(let uid, let muted):
                guard let device = MicHAL.device(uid: uid), MicHAL.setMute(device, muted) else { ok = false; continue }
            case .setVolume(let uid, let volume):
                guard let device = MicHAL.device(uid: uid), MicHAL.setVolume(device, volume) else { ok = false; continue }
            }
        }
        return ok
    }

    // MARK: Following the input device

    private func startListening() {
        guard systemListeners.isEmpty else { return }
        let system = AudioObjectID(kAudioObjectSystemObject)
        systemListeners = [
            MicHALListener(object: system, selector: kAudioHardwarePropertyDefaultInputDevice) { [weak self] in
                self?.defaultInputChanged()
            },
            MicHALListener(object: system, selector: kAudioHardwarePropertyDevices) { [weak self] in
                self?.refreshAvailability()
            },
        ].compactMap { $0 }
        if isMuted { watchMutedDevice(MicHAL.device(uid: state.deviceUID ?? "") ?? kAudioObjectUnknown) }
    }

    private func stopListening() {
        systemListeners.forEach { $0.remove() }
        systemListeners = []
        unwatchMutedDevice()
    }

    /// macOS switched the input while Orbit's mute is on: put the old device back, mute the new one (or end
    /// the mute when the new one can't be muted).
    private func defaultInputChanged() {
        refreshAvailability()
        guard state.isMuted else { return }
        let device = MicHAL.defaultInputDevice()
        let actions = state.retarget(to: MicHAL.reading(for: device))
        if !perform(actions) { Log.info("mic mute: following the input device change was incomplete") }
        if state.isMuted {
            savePendingRestore()
            watchMutedDevice(device)
        } else {
            mutedEndedOutsideOrbit()
        }
    }

    /// Listens to the muted device's mute and volume, to notice the user unmuting it elsewhere.
    private func watchMutedDevice(_ device: AudioObjectID) {
        unwatchMutedDevice()
        guard device != kAudioObjectUnknown, active else { return }
        let changed: () -> Void = { [weak self] in self?.mutedDeviceChanged(device) }
        deviceListeners = [
            MicHALListener(object: device, selector: kAudioDevicePropertyMute, scope: kAudioObjectPropertyScopeInput, action: changed),
            MicHALListener(object: device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                           scope: kAudioObjectPropertyScopeInput, action: changed),
        ].compactMap { $0 }
    }

    private func unwatchMutedDevice() {
        deviceListeners.forEach { $0.remove() }
        deviceListeners = []
    }

    private func mutedDeviceChanged(_ device: AudioObjectID) {
        guard state.isMuted, let reading = MicHAL.reading(for: device) else { return }
        if !state.deviceChanged(reading) { mutedEndedOutsideOrbit() }
    }

    /// The user unmuted the mic outside Orbit (or it can no longer be muted): Orbit's mute is over.
    private func mutedEndedOutsideOrbit() {
        clearPendingRestore()
        unwatchMutedDevice()
        isMuted = false
        updateBadge()
    }

    // MARK: Crash recovery

    private func savePendingRestore() {
        guard let restoreDefaults, let data = try? JSONEncoder().encode(state) else { return }
        restoreDefaults.set(data, forKey: Self.pendingRestoreKey)
    }

    private func clearPendingRestore() {
        restoreDefaults?.removeObject(forKey: Self.pendingRestoreKey)
    }

    /// Once per launch: a restore record still stored means the previous run crashed or was killed while it
    /// had the mic muted. Undo that mute if the mic is still exactly as Orbit left it.
    private func recoverFromPreviousRunIfNeeded() {
        guard !didRecover, let restoreDefaults else { return }
        didRecover = true
        guard let data = restoreDefaults.data(forKey: Self.pendingRestoreKey) else { return }
        restoreDefaults.removeObject(forKey: Self.pendingRestoreKey)
        guard let record = try? JSONDecoder().decode(MicMuteState.self, from: data), let uid = record.deviceUID else { return }
        let current = MicHAL.device(uid: uid).flatMap { MicHAL.reading(for: $0) }
        let actions = MicMuteState.recoveryActions(for: record, current: current)
        guard !actions.isEmpty else { return }
        Log.info("mic mute: undoing a mute left by the previous run on \(uid)")
        _ = perform(actions)
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
