import Combine
import CoreAudio
import Foundation
import OrbitCore

/// Owns every process tap, keyed by app bundle ID, and keeps them matching the user's per-app settings:
/// on every change of a preference, the default output, the device list, the audio processes or the
/// permission it runs `TapPlan` for each app and creates, retargets, updates or releases taps.
///
/// - Taps exist only while the feature runs, System Audio Recording is granted, the app has audio
///   processes, and `TapPlan.needsTap` (an app at 100 %, unmuted, on the default output has none).
/// - A tap whose app returns to 100 % on the same device plays at unity for `releaseDelay` before it is
///   released, so dragging a slider across 100 doesn't tear down and rebuild the tap on the way.
/// - A replacement tap (new device, new processes) is started before the old one is released, so the app
///   is never heard unattenuated in between.
/// - A tap that fails to build is not retried with the same app, device and processes (no retry loop).
/// - When a tapped app has been quiet for `TapActivity.idleDelay`, its aggregate's IO is stopped and re-armed
///   to restart with the app's next audio (no IO wakeups, no streaming, no sleep assertion while idle).
/// - `stop()` releases everything and waits (bounded by `stopTimeout`) for the teardown; it runs when the
///   feature is turned off and from `applicationWillTerminate` via `FeatureRegistry.stopAll()`.
@available(macOS 14.2, *)
@MainActor
final class SoundEngine {
    private struct TapKey: Equatable {
        let destination: String
        let processes: [AudioObjectID]
    }

    static let releaseDelay: TimeInterval = 1.0
    static let stopTimeout: TimeInterval = 2.0

    let monitor = AudioProcessMonitor()
    private let settings: SoundSettings
    private let hardware: AudioHardware
    private var taps: [String: AppAudioTap] = [:]
    /// Taps being replaced, kept until their successor has started.
    private var retiring: [ObjectIdentifier: AppAudioTap] = [:]
    private var failures: [String: TapKey] = [:]
    private var releases: [String: DispatchWorkItem] = [:]
    /// The device each app last played on, kept while it is idle (`AppOutputMemory`).
    private var outputMemory = AppOutputMemory()
    /// Per tap: whether its app is quiet long enough to pause the aggregate (`TapActivity`).
    private var activity: [String: TapActivity] = [:]
    /// The one pending re-check of `activity` (a single one-shot, no polling).
    private var activityCheck: DispatchWorkItem?
    private var subscriptions: Set<AnyCancellable> = []
    private var reconcileScheduled = false
    private(set) var isRunning = false

    /// The Sound tab is on screen (the process list is watched meanwhile, for the Apps list).
    var panelVisible = false {
        didSet { if panelVisible != oldValue { updateListening() } }
    }

    /// System Audio Recording is granted. Taps are only ever built when it is.
    var permissionGranted = false {
        didSet {
            guard permissionGranted != oldValue else { return }
            failures = [:]
            scheduleReconcile()
        }
    }

    /// Called after the audio processes or the taps changed (the panel refreshes its Apps list).
    var onAppsChanged: (() -> Void)?

    init(settings: SoundSettings, hardware: AudioHardware) {
        self.settings = settings
        self.hardware = hardware
    }

    /// The apps that currently have a tap.
    var tappedBundleIDs: Set<String> { Set(taps.keys) }

    /// The apps whose tap couldn't be built (or stopped working): their setting is not applied, and their row
    /// says so. Cleared when the device list or the permission changes, when the app's destination or
    /// processes change (a new attempt), or when it no longer needs a tap.
    var failedBundleIDs: Set<String> { Set(failures.keys) }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        monitor.onChange = { [weak self] in
            self?.scheduleReconcile()
            self?.onAppsChanged?()
        }
        settings.$appStates.dropFirst().sink { [weak self] _ in self?.scheduleReconcile() }.store(in: &subscriptions)
        hardware.$defaultOutputUID.dropFirst().sink { [weak self] _ in self?.scheduleReconcile() }.store(in: &subscriptions)
        hardware.$devices.dropFirst().sink { [weak self] _ in
            self?.failures = [:]
            self?.scheduleReconcile()
        }.store(in: &subscriptions)
        reconcile()
    }

    /// Releases every tap and aggregate device and waits for the teardown (bounded). Idempotent.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        subscriptions.removeAll()
        monitor.onChange = nil
        monitor.stopListening()
        releases.values.forEach { $0.cancel() }
        releases = [:]
        failures = [:]
        outputMemory = AppOutputMemory()
        activity = [:]
        activityCheck?.cancel()
        activityCheck = nil
        let all = Array(taps.values) + Array(retiring.values)
        taps = [:]
        retiring = [:]
        all.forEach { $0.invalidate() }
        let deadline = DispatchTime.now() + Self.stopTimeout
        // A tap paused for idleness may keep its queue in the re-armed start until the app's next sound; its IO
        // isn't running (the app isn't muted) and its teardown runs right after, so don't wait for it.
        for tap in all where !tap.isWaitingForAudio && !tap.waitUntilIdle(deadline: deadline) {
            Log.error("sound: teardown of \(tap.bundleID) is still pending after \(Self.stopTimeout) s")
        }
        if !all.isEmpty { Log.info("sound: released \(all.count) tap(s)") }
    }

    /// Coalesces bursts of changes (a slider drag, a flurry of process notifications) into one pass.
    func scheduleReconcile() {
        guard isRunning, !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in self?.reconcile() }
    }

    private func reconcile() {
        reconcileScheduled = false
        guard isRunning else { return }
        if !monitor.isListening { monitor.refresh() }
        let available = Set(hardware.outputDevices.map(\.uid))
        let running = monitor.apps()
        for app in running.keys { _ = outputMemory.observe(app: app, deviceUIDs: monitor.outputDeviceUIDs(forApp: app), hasProcesses: true) }
        outputMemory.forgetApps(notIn: Set(running.keys))

        var wanted: [String: (plan: TapPlan, key: TapKey)] = [:]
        if permissionGranted {
            for (bundleID, preference) in settings.appStates where !preference.isDefault {
                let plan = TapPlan(preference: preference, defaultOutputUID: followedOutput(for: bundleID), availableOutputUIDs: available)
                guard plan.needsTap, let destination = plan.destinationUID else { continue }
                let processes = monitor.processObjects(forApp: bundleID)
                guard !processes.isEmpty else { continue }
                wanted[bundleID] = (plan, TapKey(destination: destination, processes: processes))
            }
        }

        let staleFailures = failures.keys.filter { wanted[$0] == nil }
        if !staleFailures.isEmpty {
            staleFailures.forEach { failures[$0] = nil }
            onAppsChanged?()
        }

        for (bundleID, tap) in taps where wanted[bundleID] == nil {
            let plan = TapPlan(preference: settings.preference(for: bundleID), defaultOutputUID: followedOutput(for: bundleID),
                               availableOutputUIDs: available)
            let passingThroughUnity = permissionGranted && !plan.needsTap && plan.destinationUID == tap.destinationUID
                && monitor.processObjects(forApp: bundleID) == tap.processes
            if passingThroughUnity {
                tap.setGain(plan.gain)
                scheduleRelease(bundleID)
            } else {
                release(bundleID)
            }
        }

        for (bundleID, want) in wanted {
            cancelRelease(bundleID)
            if let tap = taps[bundleID], tap.destinationUID == want.key.destination, tap.processes == want.key.processes {
                tap.setGain(want.plan.gain)
                continue
            }
            if failures[bundleID] == want.key { continue }
            failures[bundleID] = nil
            build(bundleID, key: want.key, gain: want.plan.gain)
        }
        updateListening()
        updateActivity()
    }

    /// Pauses the aggregate of every tap whose app has been quiet for `TapActivity.idleDelay`, and schedules
    /// the next look for the earliest pending quiet spell. Playing again needs nothing from here: the re-armed
    /// aggregate restarts with the app's audio.
    private func updateActivity() {
        activityCheck?.cancel()
        activityCheck = nil
        guard isRunning else { return }
        let apps = monitor.apps()
        let now = Date()
        var next: Date?
        for (bundleID, tap) in taps {
            let playing = apps[bundleID]?.isPlaying ?? false
            var state = activity[bundleID] ?? TapActivity(now: now, isPlaying: playing)
            // Only a tap whose first start has returned is paused; before that its own start is already waiting
            // for the app's audio (and a tap built while quiet counts as paused from the start).
            if state.update(isPlaying: playing, now: now) == .pause, tap.hasStarted { tap.pauseUntilNextAudio() }
            activity[bundleID] = state
            if let check = state.nextCheck() { next = min(next ?? check, check) }
        }
        activity = activity.filter { taps[$0.key] != nil }
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.updateActivity() }
        activityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(next.timeIntervalSince(now), 0.05), execute: work)
    }

    /// Where "Same as Output" keeps this app: the device it plays to on its own (an app that chose one in its
    /// own settings), otherwise the system output (`TapPlan.followedOutput`). While the app is idle Core
    /// Audio reports no device, so the last one it played on is used until its processes go away.
    func followedOutput(for bundleID: String) -> String? {
        let devices = outputMemory.observe(app: bundleID, deviceUIDs: monitor.outputDeviceUIDs(forApp: bundleID),
                                           hasProcesses: !monitor.processObjects(forApp: bundleID).isEmpty)
        return TapPlan.followedOutput(appDeviceUIDs: devices, systemOutputUID: hardware.defaultOutputUID,
                                      availableOutputUIDs: Set(hardware.outputDevices.map(\.uid)))
    }

    private func build(_ bundleID: String, key: TapKey, gain: Float) {
        let previous = taps[bundleID]
        if let previous { retiring[ObjectIdentifier(previous)] = previous }
        var built: AppAudioTap?
        let retire: @MainActor () -> Void = { [weak self] in
            guard let previous else { return }
            if self?.retiring.removeValue(forKey: ObjectIdentifier(previous)) != nil { previous.invalidate() }
        }
        let tap = AppAudioTap(bundleID: bundleID, processes: key.processes, destinationUID: key.destination, gain: gain,
                              onStarted: retire,
                              onFailure: { [weak self] _ in
                                  retire()
                                  guard let self, let built, self.taps[bundleID] === built else { return }
                                  self.taps[bundleID] = nil
                                  self.activity[bundleID] = nil
                                  built.invalidate()
                                  self.failures[bundleID] = key
                                  self.onAppsChanged?()
                              })
        built = tap
        taps[bundleID] = tap
        activity[bundleID] = TapActivity(now: Date(), isPlaying: monitor.apps()[bundleID]?.isPlaying ?? false)
        onAppsChanged?()
    }

    private func release(_ bundleID: String) {
        cancelRelease(bundleID)
        guard let tap = taps.removeValue(forKey: bundleID) else { return }
        activity[bundleID] = nil
        tap.invalidate()
        onAppsChanged?()
    }

    private func scheduleRelease(_ bundleID: String) {
        guard releases[bundleID] == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.releases[bundleID] = nil
            self.release(bundleID)
        }
        releases[bundleID] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.releaseDelay, execute: work)
    }

    private func cancelRelease(_ bundleID: String) {
        releases.removeValue(forKey: bundleID)?.cancel()
    }

    /// The process list is watched while it matters: the panel is open, a tap exists, or an app has
    /// settings that should apply as soon as it starts playing. Listeners cost nothing until they fire.
    private func updateListening() {
        let pendingSettings = settings.appStates.values.contains { !$0.isDefault }
        let wanted = isRunning && permissionGranted && (panelVisible || !taps.isEmpty || pendingSettings)
        if wanted && !monitor.isListening { monitor.startListening() }
        if !wanted && monitor.isListening { monitor.stopListening() }
    }
}

/// "Keep preferred microphone" (off by default): when the input device moves away from the preferred
/// microphone while it is connected, switch back. Runs only while Sound is on.
@MainActor
final class PreferredMicWatcher {
    private let settings: SoundSettings
    private let hardware: AudioHardware
    private var subscriptions: Set<AnyCancellable> = []
    private var lastSwitch = Date.distantPast
    private var checkScheduled = false
    private var retryScheduled = false

    init(settings: SoundSettings, hardware: AudioHardware) {
        self.settings = settings
        self.hardware = hardware
    }

    func start() {
        guard subscriptions.isEmpty else { return }
        hardware.$defaultInputUID.sink { [weak self] _ in self?.scheduleCheck() }.store(in: &subscriptions)
        hardware.$devices.sink { [weak self] _ in self?.scheduleCheck() }.store(in: &subscriptions)
        settings.$keepPreferredMic.sink { [weak self] _ in self?.scheduleCheck() }.store(in: &subscriptions)
        settings.$preferredMicUID.sink { [weak self] _ in self?.scheduleCheck() }.store(in: &subscriptions)
    }

    func stop() {
        subscriptions.removeAll()
    }

    private func scheduleCheck() {
        guard !checkScheduled else { return }
        checkScheduled = true
        DispatchQueue.main.async { [weak self] in self?.check() }
    }

    private func check() {
        checkScheduled = false
        guard !subscriptions.isEmpty, let preferred = settings.preferredMicUID else { return }
        let available = Set(hardware.inputDevices.map(\.uid))
        guard PreferredMicPolicy.shouldSwitchBack(currentUID: hardware.defaultInputUID, preferredUID: preferred,
                                                  availableUIDs: available, keep: settings.keepPreferredMic) else { return }
        // One switch per throttle window at most, so a device that refuses can't start a tug of war. A change
        // inside the window is looked at again when it ends instead of being dropped.
        if let delay = PreferredMicPolicy.retryDelay(lastSwitch: lastSwitch, now: Date()) {
            guard !retryScheduled else { return }
            retryScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05) { [weak self] in
                self?.retryScheduled = false
                self?.scheduleCheck()
            }
            return
        }
        lastSwitch = Date()
        Log.info("sound: input moved to \(hardware.defaultInputUID ?? "none"); switching back to the preferred microphone")
        hardware.setDefaultInput(uid: preferred)
    }
}
