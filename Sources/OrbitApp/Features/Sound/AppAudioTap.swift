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
/// - `invalidate()` stops the IOProc, destroys the aggregate, then the tap, in every state: when the tap's
///   queue sits in a start that waits for the app's audio (TapAutoStart), the teardown runs from outside the
///   queue at once (`TapLifecycle`), and the queue stops when that start returns. `SoundEngine.stop()` waits
///   for the release (bounded) when the feature is turned off and when Orbit quits.
/// - Creation fails closed: an unexpected tap format or stream layout, or a destination device whose own
///   input streams can't be switched off (so a headset's microphone would start), destroys everything
///   created so far and leaves the app untouched.
///
/// HAL work for one tap runs on that tap's own serial queue, never the main thread: creating an aggregate
/// device takes a while, and with `kAudioAggregateDeviceTapAutoStartKey` a start waits for the app's audio.
/// A per-tap queue means one silent app can't hold up another app's tap.
@available(macOS 14.2, *)
final class AppAudioTap: @unchecked Sendable {
    let bundleID: String
    let destinationUID: String
    let processes: [AudioObjectID]
    private let renderState: TapRenderState
    private let queue: DispatchQueue
    private let onFailure: @MainActor (String) -> Void

    /// Guards the lifecycle and the HAL object IDs, which the tap's queue and an outside teardown both touch.
    private let lock = NSLock()
    private var lifecycle = TapLifecycle()
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var startedFlag = false
    /// Signalled once the teardown has run (whoever ran it).
    private let released = DispatchSemaphore(value: 0)

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// The tap's first start has returned (its IO has run at least once). Only then may it be paused for
    /// idleness: before that, its own TapAutoStart start is already waiting for the app's audio.
    var hasStarted: Bool { locked { startedFlag } }

    /// The tap was released while its queue was busy; creation stops there without reporting a failure.
    private struct Released: Error {}

    /// Builds the tap on its queue and starts it. On the main thread afterwards: `onStarted` once it runs,
    /// or `onFailure` if creation failed (nothing is left behind then) or a later restart of its IO failed.
    /// A tap released before it got going reports neither.
    init(bundleID: String, processes: [AudioObjectID], destinationUID: String, gain: Float,
         onStarted: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (String) -> Void) {
        self.bundleID = bundleID
        self.processes = processes
        self.destinationUID = destinationUID
        self.onFailure = onFailure
        renderState = TapRenderState(gain: gain)
        queue = DispatchQueue(label: "com.kevo.orbit.sound.tap.\(bundleID)", qos: .userInitiated)
        queue.async { [self] in
            do {
                try create()
                locked { startedFlag = true }
                Log.info("sound: tapped \(bundleID) (\(processes.count) processes) → \(destinationUID)")
                DispatchQueue.main.async { onStarted() }
            } catch is Released {
                teardown()
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
            let device: (aggregate: AudioObjectID, proc: AudioDeviceIOProcID)? = locked {
                guard !lifecycle.isInvalidated, !lifecycle.isTornDown, aggregateID != kAudioObjectUnknown,
                      let proc = ioProcID else { return nil }
                return (aggregateID, proc)
            }
            guard let device else { return }
            // The decision was made on the main thread a moment ago: if the app has started playing since, stopping
            // now would cut it off (and let it through unattenuated until the IO is back). Leave it running.
            guard !processesArePlaying() else { return }
            AudioDeviceStop(device.aggregate, device.proc)
            // Released meanwhile: the teardown is queued right behind this block.
            guard locked({ lifecycle.beginWaitingStart() }) else { return }
            Log.info("sound: \(bundleID) is quiet; its output waits for the next sound")
            let began = Date()
            let status = AudioDeviceStart(device.aggregate, device.proc)
            // Released while waiting: torn down from outside already.
            guard locked({ lifecycle.endWaitingStart() }) else {
                Log.info("sound: \(bundleID)'s re-armed start returned after its release (blocked \(Self.seconds(since: began)), status \(status))")
                return
            }
            if status == noErr { Log.info("sound: \(bundleID) is playing again (its start waited \(Self.seconds(since: began)))") }
            guard status != noErr else { return }
            // The IO won't come back: the app plays as usual meanwhile; let the engine drop this tap.
            Log.error("sound: re-arming \(bundleID) failed (\(status))")
            let report = onFailure
            DispatchQueue.main.async { report("restarting its output failed (\(status))") }
        }
    }

    /// Whether any of the tapped processes is playing right now (a plain HAL read, safe off the main thread).
    private func processesArePlaying() -> Bool {
        processes.contains { process in
            (SoundHAL.read(process, SoundHAL.address(kAudioProcessPropertyIsRunningOutput), zero: UInt32(0)) ?? 0) != 0
        }
    }

    /// Stops and destroys everything, without waiting for a start that may block: on the tap's queue normally,
    /// from outside it at once while the queue waits for the app's audio. Idempotent.
    func invalidate() {
        switch locked({ lifecycle.invalidate() }) {
        case .alreadyDone:
            return
        case .onQueue:
            queue.async { [self] in teardown() }
        case .fromOutside:
            Log.info("sound: releasing \(bundleID) from outside its waiting start")
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                let began = Date()
                teardown()
                Log.info("sound: outside teardown of \(bundleID) finished in \(Self.seconds(since: began))")
            }
        }
    }

    /// "0.42 s", for the logs that hardware checks read.
    private static func seconds(since start: Date) -> String {
        String(format: "%.2f s", Date().timeIntervalSince(start))
    }

    /// Blocks until the teardown has run, or `deadline` passes. Returns false on timeout (the teardown still
    /// runs, and Orbit exiting destroys private taps anyway).
    func waitUntilReleased(deadline: DispatchTime) -> Bool {
        guard released.wait(timeout: deadline) == .success else { return false }
        released.signal()   // let any other waiter through too
        return true
    }

    // MARK: Building (on the queue)

    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw Failure(description: "\(what) failed (\(status))") }
    }

    /// Throws `Released` when the tap was released while it was being built.
    private func ensureAlive() throws {
        if locked({ lifecycle.isInvalidated || lifecycle.isTornDown }) { throw Released() }
    }

    private func create() throws {
        try ensureAlive()
        // 1. The tap: a stereo mix of the app's processes, muted at the source while Orbit reads it.
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "Orbit \(bundleID)"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "AudioHardwareCreateProcessTap")
        locked { tapID = tap }
        try ensureAlive()

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
        locked { aggregateID = aggregate }
        try ensureAlive()

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
        locked { ioProcID = procID }

        // 5. Only the tap's streams are used, so the device's own inputs (a headset's mic) never start.
        let usageSet = Self.setInputStreamUsage(aggregate: aggregate, procID: procID, streamCount: aggregateInputs.count, on: tapBuffers)
        if !usageSet && !deviceInputs.isEmpty {
            throw Failure(description: "couldn't switch off the output device's own input streams")
        }

        // 6. Start. With TapAutoStart this may only return with the app's first audio; a release meanwhile
        //    tears down from outside (`invalidate()`), and then nothing more happens here.
        guard locked({ lifecycle.beginWaitingStart() }) else { throw Released() }
        let began = Date()
        let status = AudioDeviceStart(aggregate, procID)
        guard locked({ lifecycle.endWaitingStart() }) else {
            Log.info("sound: \(bundleID)'s first start returned after its release (blocked \(Self.seconds(since: began)), status \(status))")
            throw Released()
        }
        try check(status, "AudioDeviceStart")
        Log.info("sound: \(bundleID)'s first start returned after \(Self.seconds(since: began))")
    }

    /// Stop the IOProc, destroy the aggregate, then the tap. Runs once, from whichever side claims it.
    private func teardown() {
        let objects: (tap: AudioObjectID, aggregate: AudioObjectID, proc: AudioDeviceIOProcID?)? = locked {
            guard lifecycle.claimTeardown() else { return nil }
            defer {
                tapID = kAudioObjectUnknown
                aggregateID = kAudioObjectUnknown
                ioProcID = nil
            }
            return (tapID, aggregateID, ioProcID)
        }
        guard let objects else { return }
        if objects.aggregate != kAudioObjectUnknown, let proc = objects.proc {
            AudioDeviceStop(objects.aggregate, proc)
            AudioDeviceDestroyIOProcID(objects.aggregate, proc)
        }
        if objects.aggregate != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(objects.aggregate)
            if status != noErr { Log.error("sound: destroying the aggregate for \(bundleID) failed (\(status))") }
        }
        if objects.tap != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(objects.tap)
            if status != noErr { Log.error("sound: destroying the tap for \(bundleID) failed (\(status))") }
            Log.info("sound: released \(bundleID)")
        }
        released.signal()
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
