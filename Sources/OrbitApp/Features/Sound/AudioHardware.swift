import AudioToolbox
import Combine
import CoreAudio
import OrbitCore

/// A connected audio device.
struct AudioDevice: Identifiable, Equatable {
    let objectID: AudioObjectID
    let summary: AudioDeviceSummary
    var id: String { summary.uid }
    var uid: String { summary.uid }
}

/// The audio devices and the system's choices among them: default output, the alerts ("system") output,
/// default input, plus the output's master volume and the input's level. Reads are live HAL reads; the
/// published values follow property listeners that exist only between `start()` and `stop()`.
///
/// The setters change real system settings and are only ever called from the user's own clicks in the
/// panel (and by `PreferredMicWatcher` when the user turned that on).
@MainActor
final class AudioHardware: ObservableObject {
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var defaultOutputUID: String?
    @Published private(set) var systemOutputUID: String?
    @Published private(set) var defaultInputUID: String?
    /// The default output's master volume (0…1), nil when it has none (DisplayPort audio, for example).
    @Published private(set) var outputVolume: Float?
    @Published private(set) var outputMuted = false
    /// The default input's level (0…1), nil when it has none, or ignores it (`MicsIgnoringMute`).
    @Published private(set) var inputVolume: Float?

    private var systemListeners: [SoundHALListener] = []
    private var outputListeners: [SoundHALListener] = []
    private var inputListeners: [SoundHALListener] = []
    /// The device objects the volume listeners are on (re-attached when the object changes).
    private var watchedOutput = AudioObjectID(kAudioObjectUnknown)
    private var watchedInput = AudioObjectID(kAudioObjectUnknown)
    private(set) var isRunning = false

    var outputDevices: [AudioDevice] { devices.filter(\.summary.hasOutput) }
    var inputDevices: [AudioDevice] { devices.filter(\.summary.hasInput) }

    func device(uid: String?) -> AudioDevice? {
        guard let uid else { return nil }
        return devices.first { $0.uid == uid }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        let system = SoundHAL.system
        systemListeners = [
            SoundHALListener(object: system, SoundHAL.address(kAudioHardwarePropertyDevices)) { [weak self] in self?.refreshDevices() },
            SoundHALListener(object: system, SoundHAL.address(kAudioHardwarePropertyDefaultOutputDevice)) { [weak self] in self?.refreshDefaults() },
            SoundHALListener(object: system, SoundHAL.address(kAudioHardwarePropertyDefaultSystemOutputDevice)) { [weak self] in self?.refreshDefaults() },
            SoundHALListener(object: system, SoundHAL.address(kAudioHardwarePropertyDefaultInputDevice)) { [weak self] in self?.refreshDefaults() },
        ].compactMap { $0 }
        refreshDevices()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        (systemListeners + outputListeners + inputListeners).forEach { $0.remove() }
        systemListeners = []
        outputListeners = []
        inputListeners = []
        watchedOutput = kAudioObjectUnknown
        watchedInput = kAudioObjectUnknown
    }

    // MARK: Reading

    func refreshDevices() {
        let list = SoundHAL.allDevices().compactMap(Self.describe)
        if list != devices { devices = list }
        refreshDefaults()
    }

    func refreshDefaults() {
        let output = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let input = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let alerts = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
        let outputUID = SoundHAL.uid(of: output), inputUID = SoundHAL.uid(of: input), alertsUID = SoundHAL.uid(of: alerts)
        if outputUID != defaultOutputUID { defaultOutputUID = outputUID }
        if inputUID != defaultInputUID { defaultInputUID = inputUID }
        if alertsUID != systemOutputUID { systemOutputUID = alertsUID }
        // Listeners follow the object, not the UID: a device that re-enumerates (sleep, a USB reset) keeps its
        // UID under a new object ID, and the old object's listeners would never fire again.
        if isRunning && output != watchedOutput { watchOutput(output) }
        if isRunning && input != watchedInput { watchInput(input) }
        refreshVolumes()
    }

    func refreshVolumes() {
        let output = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let input = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let outVolume = Self.volume(output, scope: kAudioObjectPropertyScopeOutput)
        let outMuted = (SoundHAL.read(output, SoundHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput), zero: UInt32(0)) ?? 0) != 0
        let ignoresVolume = MicsIgnoringMute.contains(modelUID: SoundHAL.string(input, SoundHAL.address(kAudioDevicePropertyModelUID)))
        let inVolume = ignoresVolume ? nil : Self.volume(input, scope: kAudioObjectPropertyScopeInput)
        if outVolume != outputVolume { outputVolume = outVolume }
        if outMuted != outputMuted { outputMuted = outMuted }
        if inVolume != inputVolume { inputVolume = inVolume }
    }

    private func watchOutput(_ device: AudioObjectID) {
        outputListeners.forEach { $0.remove() }
        outputListeners = []
        watchedOutput = device
        guard isRunning, device != kAudioObjectUnknown else { return }
        outputListeners = [
            SoundHALListener(object: device, SoundHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.refreshVolumes() },
            SoundHALListener(object: device, SoundHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)) { [weak self] in self?.refreshVolumes() },
        ].compactMap { $0 }
    }

    private func watchInput(_ device: AudioObjectID) {
        inputListeners.forEach { $0.remove() }
        inputListeners = []
        watchedInput = device
        guard isRunning, device != kAudioObjectUnknown else { return }
        inputListeners = [
            SoundHALListener(object: device, SoundHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput)) { [weak self] in self?.refreshVolumes() },
        ].compactMap { $0 }
    }

    /// A device's summary, or nil for hidden devices, Orbit's own private aggregates, and devices with no
    /// channels at all.
    static func describe(_ device: AudioObjectID) -> AudioDevice? {
        guard let uid = SoundHAL.uid(of: device), !uid.hasPrefix(SoundHAL.aggregateUIDPrefix) else { return nil }
        if (SoundHAL.read(device, SoundHAL.address(kAudioDevicePropertyIsHidden), zero: UInt32(0)) ?? 0) != 0 { return nil }
        let inputs = SoundHAL.streamChannels(device, scope: kAudioObjectPropertyScopeInput).reduce(0, +)
        let outputs = SoundHAL.streamChannels(device, scope: kAudioObjectPropertyScopeOutput).reduce(0, +)
        guard inputs + outputs > 0 else { return nil }
        let name = SoundHAL.string(device, SoundHAL.address(kAudioObjectPropertyName)) ?? ""
        let transport = AudioTransport(fourCC: SoundHAL.read(device, SoundHAL.address(kAudioDevicePropertyTransportType), zero: UInt32(0)) ?? 0)
        return AudioDevice(objectID: device, summary: AudioDeviceSummary(uid: uid, name: name, inputChannels: inputs,
                                                                         outputChannels: outputs, transport: transport))
    }

    /// The device's virtual main volume on one side, when it has a settable one.
    private static func volume(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        let addr = SoundHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope)
        guard SoundHAL.isSettable(device, addr) else { return nil }
        return SoundHAL.read(device, addr, zero: Float32(0))
    }

    // MARK: Changing (user actions only)

    func setDefaultOutput(uid: String) { setDefault(kAudioHardwarePropertyDefaultOutputDevice, uid: uid) }
    func setSystemOutput(uid: String) { setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, uid: uid) }
    func setDefaultInput(uid: String) { setDefault(kAudioHardwarePropertyDefaultInputDevice, uid: uid) }

    private func setDefault(_ selector: AudioObjectPropertySelector, uid: String) {
        guard let device = device(uid: uid)?.objectID ?? SoundHAL.device(uid: uid) else { return }
        let status = SoundHAL.write(SoundHAL.system, SoundHAL.address(selector), device)
        if status != noErr { Log.error("sound: couldn't set default device \(uid): \(status)") }
        refreshDefaults()
    }

    /// Sets the default output's master volume (0…1). Raising it above 0 also unmutes, like the volume keys.
    func setOutputVolume(_ value: Float) {
        let device = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let addr = SoundHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeOutput)
        guard SoundHAL.isSettable(device, addr) else { return }
        SoundHAL.write(device, addr, Float32(min(max(value, 0), 1)))
        let mute = SoundHAL.address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        if value > 0, outputMuted, SoundHAL.isSettable(device, mute) { SoundHAL.write(device, mute, UInt32(0)) }
        refreshVolumes()
    }

    /// Sets the default input's level (0…1).
    func setInputVolume(_ value: Float) {
        let device = SoundHAL.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        let addr = SoundHAL.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioObjectPropertyScopeInput)
        guard SoundHAL.isSettable(device, addr) else { return }
        SoundHAL.write(device, addr, Float32(min(max(value, 0), 1)))
        refreshVolumes()
    }
}
