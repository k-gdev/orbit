import AudioToolbox
import CoreAudio
import Foundation
import OrbitCore

/// One app's audio taken over by Orbit: a Core Audio process tap on the app's processes, a private
/// aggregate device (the destination output as sub-device plus the tap), and an IOProc that plays the
/// tap's audio on that output at the app's volume (`TapRenderer`).
///
/// Safety (Review Focus 1):
/// - The tap is `muteBehavior = .mutedWhenTapped`: the app is silenced only while Orbit's IOProc is
///   reading the tap. If the IOProc stops for any reason, the app is heard again as usual.
/// - The tap (`isPrivate`) and the aggregate device (`kAudioAggregateDeviceIsPrivateKey`) belong to Orbit's
///   process alone and the system destroys them when Orbit exits, even after a crash.
/// - `invalidate()` stops the IOProc, destroys the aggregate, then the tap; `SoundEngine.stop()` waits for
///   it (bounded) when the feature is turned off and when Orbit quits.
/// - Creation fails closed: an unexpected tap format or stream layout, or a destination device whose own
///   input streams can't be switched off (so a headset's microphone would start), destroys everything
///   created so far and leaves the app untouched.
///
/// Every HAL call for one tap runs on that tap's own serial queue, never the main thread: creating an
/// aggregate device takes a while, and with `kAudioAggregateDeviceTapAutoStartKey` the start waits for the
/// app's first audio. A per-tap queue means one silent app can't hold up another app's tap.
@available(macOS 14.2, *)
final class AppAudioTap: @unchecked Sendable {
    let bundleID: String
    let destinationUID: String
    let processes: [AudioObjectID]
    private let renderState: TapRenderState
    private let queue: DispatchQueue
    private let onFailure: @MainActor (String) -> Void

    // Touched only on `queue`.
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var invalidated = false

    /// Set while the queue sits in a re-armed `AudioDeviceStart` (paused for idleness), which with
    /// TapAutoStart may only return with the app's next audio. Read from the main thread.
    private let waitingLock = NSLock()
    private var waitingForAudioFlag = false

    /// The aggregate's IO is stopped and re-armed for the app's next audio; the app is not muted meanwhile
    /// (`.mutedWhenTapped`), so `SoundEngine.stop()` need not wait for this tap's queue.
    var isWaitingForAudio: Bool {
        waitingLock.lock(); defer { waitingLock.unlock() }
        return waitingForAudioFlag
    }

    private func setWaitingForAudio(_ on: Bool) {
        waitingLock.lock(); waitingForAudioFlag = on; waitingLock.unlock()
    }

    /// Builds the tap on its queue and starts it. On the main thread afterwards: `onStarted` once it runs,
    /// or `onFailure` if creation failed (nothing is left behind then) or a later restart of its IO failed.
    init(bundleID: String, processes: [AudioObjectID], destinationUID: String, gain: Float,
         onStarted: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (String) -> Void) {
        self.bundleID = bundleID
        self.processes = processes
        self.destinationUID = destinationUID
        self.onFailure = onFailure
        renderState = TapRenderState(gain: gain)
        queue = DispatchQueue(label: "com.kevo.orbit.sound.tap.\(bundleID)", qos: .userInitiated)
        queue.async { [self] in
            guard !invalidated else { return }
            do {
                try create()
                Log.info("sound: tapped \(bundleID) (\(processes.count) processes) → \(destinationUID)")
                DispatchQueue.main.async { onStarted() }
            } catch {
                let reason = String(describing: error)
                Log.error("sound: couldn't tap \(bundleID): \(reason)")
                teardown()
                DispatchQueue.main.async { onFailure(reason) }
            }
        }
    }

    /// The gain the IOProc ramps to (0 = muted). Cheap; safe from the main thread at any time.
    func setGain(_ gain: Float) {
        renderState.setTarget(gain)
    }

    /// The app went quiet (`TapActivity`): stop the aggregate's IO, then start it again. With
    /// `kAudioAggregateDeviceTapAutoStartKey` the restarted IO only runs once the app produces audio again, so
    /// an idle app costs no IO, and the tap and aggregate stay as they are (nothing is rebuilt).
    func pauseUntilNextAudio() {
        queue.async { [self] in
            guard !invalidated, aggregateID != kAudioObjectUnknown, let procID = ioProcID else { return }
            AudioDeviceStop(aggregateID, procID)
            Log.info("sound: \(bundleID) is quiet; its output waits for the next sound")
            setWaitingForAudio(true)
            let status = AudioDeviceStart(aggregateID, procID)
            setWaitingForAudio(false)
            guard status != noErr, !invalidated else { return }
            // The IO won't come back: the app plays as usual meanwhile; let the engine drop this tap.
            Log.error("sound: re-arming \(bundleID) failed (\(status))")
            let report = onFailure
            DispatchQueue.main.async { report("restarting its output failed (\(status))") }
        }
    }

    /// Stops and destroys everything (asynchronously, on the tap's queue). Idempotent.
    func invalidate() {
        queue.async { [self] in
            invalidated = true
            teardown()
        }
    }

    /// Blocks until work queued so far (creation, `invalidate()`) has run, or `deadline` passes. Returns
    /// false on timeout (the queued teardown still runs later, and Orbit exiting destroys private taps).
    func waitUntilIdle(deadline: DispatchTime) -> Bool {
        let done = DispatchSemaphore(value: 0)
        queue.async { done.signal() }
        return done.wait(timeout: deadline) == .success
    }

    // MARK: On the queue

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure(description: "\(what) failed (\(status))") }
    }

    private func create() throws {
        // 1. The tap: a stereo mix of the app's processes, muted at the source while Orbit reads it.
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Orbit \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        tapID = tap

        guard let format = SoundHAL.read(tap, SoundHAL.address(kAudioTapPropertyFormat), zero: AudioStreamBasicDescription()),
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame >= 1 else {
            throw Failure(description: "the tap's format is not 32-bit float PCM")
        }
        let tapUID = SoundHAL.string(tap, SoundHAL.address(kAudioTapPropertyUID)) ?? description.uuid.uuidString

        // 2. A private aggregate: the destination output (clock and output streams) plus the tap.
        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orbit \(bundleID)",
            kAudioAggregateDeviceUIDKey: SoundHAL.aggregateUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: destinationUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: destinationUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID, kAudioSubTapDriftCompensationKey: true]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregate), "AudioHardwareCreateAggregateDevice")
        aggregateID = aggregate

        // 3. Which of the aggregate's input buffers are the tap's (the rest are the device's own inputs).
        let deviceInputs = SoundHAL.device(uid: destinationUID).map { SoundHAL.streamChannels($0, scope: kAudioObjectPropertyScopeInput) } ?? []
        let aggregateInputs = SoundHAL.streamChannels(aggregate, scope: kAudioObjectPropertyScopeInput)
        guard let tapBuffers = TapStreamLayout.tapBuffers(aggregateInputs: aggregateInputs, deviceInputs: deviceInputs,
                                                          tapChannels: Int(format.mChannelsPerFrame)) else {
            throw Failure(description: "unexpected aggregate input layout \(aggregateInputs) (device inputs \(deviceInputs))")
        }
        renderState.tapBuffers = tapBuffers

        // 4. The IOProc, called on the HAL's real-time IO thread.
        let state = renderState
        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregate, nil) { _, input, _, output, _ in
            state.render(input: input, output: output)
        }, "AudioDeviceCreateIOProcIDWithBlock")
        guard let procID else { throw Failure(description: "no IOProc") }
        ioProcID = procID

        // 5. Only the tap's streams are used, so the device's own inputs (a headset's mic) never start.
        let usageSet = Self.setInputStreamUsage(aggregate: aggregate, procID: procID, streamCount: aggregateInputs.count, on: tapBuffers)
        if !usageSet && !deviceInputs.isEmpty {
            throw Failure(description: "couldn't switch off the output device's own input streams")
        }

        try check(AudioDeviceStart(aggregate, procID), "AudioDeviceStart")
    }

    /// Stop the IOProc, destroy the aggregate, then the tap.
    private func teardown() {
        if aggregateID != kAudioObjectUnknown, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { Log.error("sound: destroying the aggregate for \(bundleID) failed (\(status))") }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { Log.error("sound: destroying the tap for \(bundleID) failed (\(status))") }
            tapID = kAudioObjectUnknown
            Log.info("sound: released \(bundleID)")
        }
    }

    /// `kAudioDevicePropertyIOProcStreamUsage` on the input side: only `on` streams are used by the IOProc.
    private static func setInputStreamUsage(aggregate: AudioObjectID, procID: AudioDeviceIOProcID, streamCount: Int, on: Range<Int>) -> Bool {
        guard streamCount > 0 else { return true }
        let offset = MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \AudioHardwareIOProcStreamUsage.mStreamIsOn) ?? 12
        let size = offset + MemoryLayout<UInt32>.stride * streamCount
        let raw = UnsafeMutableRawPointer.allocate(byteCount: max(size, MemoryLayout<AudioHardwareIOProcStreamUsage>.size),
                                                   alignment: MemoryLayout<AudioHardwareIOProcStreamUsage>.alignment)
        defer { raw.deallocate() }
        let usage = raw.bindMemory(to: AudioHardwareIOProcStreamUsage.self, capacity: 1)
        usage.pointee.mIOProc = unsafeBitCast(procID, to: UnsafeMutableRawPointer.self)
        usage.pointee.mNumberStreams = UInt32(streamCount)
        let flags = (raw + offset).bindMemory(to: UInt32.self, capacity: streamCount)
        for index in 0..<streamCount { flags[index] = on.contains(index) ? 1 : 0 }
        var addr = SoundHAL.address(kAudioDevicePropertyIOProcStreamUsage, kAudioObjectPropertyScopeInput)
        return AudioObjectSetPropertyData(aggregate, &addr, 0, nil, UInt32(size), raw) == noErr
    }
}

/// The state shared between the main thread (the target gain) and the IO thread (the ramp and the
/// renderer). The target is one aligned 32-bit float, written whole and read whole, so a read never tears;
/// everything else is touched only by the IO thread (or before the IOProc starts).
final class TapRenderState: @unchecked Sendable {
    private let target: UnsafeMutablePointer<Float>
    private var ramp: GainRamp
    var tapBuffers: Range<Int> = 0..<0

    init(gain: Float) {
        target = .allocate(capacity: 1)
        target.initialize(to: gain)
        ramp = GainRamp(gain: gain)
    }

    deinit { target.deallocate() }

    func setTarget(_ gain: Float) {
        target.pointee = gain.isFinite ? max(gain, 0) : 0
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        ramp.target = target.pointee
        TapRenderer.render(input: input, output: output, tapBuffers: tapBuffers, ramp: &ramp)
    }
}
