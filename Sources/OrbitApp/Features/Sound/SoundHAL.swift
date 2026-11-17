import AudioToolbox
import CoreAudio
import Foundation
import OrbitCore

/// Small typed wrappers over the Core Audio HAL property API for the Sound feature.
enum SoundHAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    /// The UID prefix of Orbit's own private aggregate devices (one per process tap). They are visible only
    /// to Orbit's process, and the device lists hide them.
    static let aggregateUIDPrefix = "com.kevo.orbit.tap."

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func has(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        return object != kAudioObjectUnknown && AudioObjectHasProperty(object, &addr)
    }

    static func isSettable(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> Bool {
        var addr = addr
        guard has(object, addr) else { return false }
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &addr, &settable) == noErr && settable.boolValue
    }

    /// A fixed-size value (`UInt32`, `Float32`, `AudioObjectID`, `pid_t`, `AudioStreamBasicDescription`).
    static func read<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, zero: T) -> T? {
        var addr = addr
        guard has(object, addr) else { return nil }
        var value = zero
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        return status == noErr ? value : nil
    }

    @discardableResult
    static func write<T>(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ value: T) -> OSStatus {
        var addr = addr
        var value = value
        return withUnsafePointer(to: &value) { AudioObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<T>.size), $0) }
    }

    /// A CFString property (names, UIDs, bundle IDs). The HAL hands over a +1 reference.
    static func string(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String? {
        var addr = addr
        guard has(object, addr) else { return nil }
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &addr, 0, nil, &size, $0) }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// An array of object IDs (devices, processes, streams).
    static func objects(_ object: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var addr = addr
        guard has(object, addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    /// Channels per stream on one side of a device (`kAudioDevicePropertyStreamConfiguration`), in the
    /// order the IOProc sees the buffers.
    static func streamChannels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [Int] {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        guard has(device, addr) else { return [] }
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, raw) == noErr else { return [] }
        return UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self)).map { Int($0.mNumberChannels) }
    }

    static func uid(of device: AudioObjectID) -> String? {
        string(device, address(kAudioDevicePropertyDeviceUID))
    }

    /// Every device of the system, as listed by the HAL.
    static func allDevices() -> [AudioObjectID] {
        objects(system, address(kAudioHardwarePropertyDevices))
    }

    static func device(uid: String) -> AudioObjectID? {
        guard !uid.isEmpty else { return nil }
        return allDevices().first { self.uid(of: $0) == uid }
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID {
        read(system, address(selector), zero: AudioObjectID(kAudioObjectUnknown)) ?? kAudioObjectUnknown
    }
}

/// One Core Audio property listener delivered on the main queue; `remove()` (or deinit) takes it off.
final class SoundHALListener {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let block: AudioObjectPropertyListenerBlock
    private var installed = false

    /// Nil when the object lacks the property or the HAL refuses the listener.
    init?(object: AudioObjectID, _ address: AudioObjectPropertyAddress, action: @escaping @MainActor () -> Void) {
        self.object = object
        self.address = address
        block = { _, _ in MainActor.assumeIsolated { action() } }
        guard SoundHAL.has(object, address),
              AudioObjectAddPropertyListenerBlock(object, &self.address, DispatchQueue.main, block) == noErr else { return nil }
        installed = true
    }

    func remove() {
        guard installed else { return }
        installed = false
        AudioObjectRemovePropertyListenerBlock(object, &address, DispatchQueue.main, block)
    }

    deinit { remove() }
}
