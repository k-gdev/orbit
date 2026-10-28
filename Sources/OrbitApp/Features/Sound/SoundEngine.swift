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
///   is never heard unattenuated in between. `TapRoster` keeps that bookkeeping: a start releases every older
///   tap of the app, a failure of the current tap releases it and every older one (a failed replaced tap takes
///   only itself), and releasing an app releases all its taps, so no replaced tap can outlive its app's release.
///   Only the newest replaced tap that has started is kept that way; replaced taps that never started (a quiet
///   app rebuilt as its output flaps) are released at once, so they can't pile up. While the app plays, the newest
///   one not yet noted as started is kept too (its start may just have returned).
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
    /// Each app's current tap and the replaced ones still alive (`TapRoster`), by serial number.
    private var roster = TapRoster<Int>()
    /// Every live tap by serial number (serials are never reused, unlike object addresses, so a late callback
    /// from a released tap can't be mistaken for a newer one).
    private var alive: [Int: AppAudioTap] = [:]
    private var nextSerial = 1
    private var failures: [String: TapKey] = [:]
    private var releases: [String: DispatchWorkItem] = [:]
    /// The device each app last played on, kept while it is idle (`AppOutputMemory`).
    private var outputMemory = AppOutputMemory()
    /// The system output `outputMemory` was last told about.
    private var lastSystemOutput: String?
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
    var tappedBundleIDs: Set<String> { Set(roster.currentByApp.keys) }

    /// The app's current tap.
    private func currentTap(_ bundleID: String) -> AppAudioTap? {
        roster.current(for: bundleID).flatMap { alive[$0] }
    }

    /// Every app's current tap.
    private var currentTaps: [(bundleID: String, tap: AppAudioTap)] {
        roster.currentByApp.compactMap { app, serial in alive[serial].map { (app, $0) } }
    }

    /// Invalidates (and forgets) the taps the roster handed back.
    private func releaseTaps(_ serials: [Int]) {
        for serial in serials { alive.removeValue(forKey: serial)?.invalidate() }
    }

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
        lastSystemOutput = nil
        activity = [:]
        activityCheck?.cancel()
        activityCheck = nil
        _ = roster.releaseAll()
        let all = Array(alive.values)
        alive = [:]
        all.forEach { $0.invalidate() }
        let deadline = DispatchTime.now() + Self.stopTimeout
        // Every tap releases promptly, including one whose queue waits in a TapAutoStart start (it is torn down
        // from outside that queue), so this normally takes milliseconds.
        for tap in all where !tap.waitUntilReleased(deadline: deadline) {
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
        noteSystemOutput()
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

        for (bundleID, tap) in currentTaps where wanted[bundleID] == nil {
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
            if let tap = currentTap(bundleID), tap.destinationUID == want.key.destination, tap.processes == want.key.processes {
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
        let now = ContinuousClock.now
        var next: ContinuousClock.Instant?
        for (bundleID, tap) in currentTaps {
            let playing = apps[bundleID]?.isPlaying ?? false
            var state = activity[bundleID] ?? TapActivity(now: now, isPlaying: playing)
            // Only a tap whose first start has returned is paused; before that its own start is already waiting
            // for the app's audio (and a tap built while quiet counts as paused from the start).
            if state.update(isPlaying: playing, now: now) == .pause, tap.hasStarted { tap.pauseUntilNextAudio() }
            activity[bundleID] = state
            if let check = state.nextCheck() { next = min(next ?? check, check) }
        }
        activity = activity.filter { roster.current(for: $0.key) != nil }
        guard let next else { return }
        let work = DispatchWorkItem { [weak self] in self?.updateActivity() }
        activityCheck = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max((next - now) / .seconds(1), 0.05), execute: work)
    }

    /// Where "Same as Output" keeps this app: the device it plays to on its own (an app that chose one in its
    /// own settings), otherwise the system output (`TapPlan.followedOutput`). While the app is idle Core
    /// Audio reports no device, so the last one it played on is used until its processes go away.
    func followedOutput(for bundleID: String) -> String? {
        noteSystemOutput()
        let devices = outputMemory.observe(app: bundleID, deviceUIDs: monitor.outputDeviceUIDs(forApp: bundleID),
                                           hasProcesses: !monitor.processObjects(forApp: bundleID).isEmpty)
        return TapPlan.followedOutput(appDeviceUIDs: devices, systemOutputUID: hardware.defaultOutputUID,
                                      availableOutputUIDs: Set(hardware.outputDevices.map(\.uid)))
    }

    /// When the system output switched, idle apps that were following it forget the old device, so they
    /// follow the switch instead of staying planned on the old output (N4).
    private func noteSystemOutput() {
        let current = hardware.defaultOutputUID
        guard current != lastSystemOutput else { return }
        outputMemory.systemOutputChanged(from: lastSystemOutput)
        lastSystemOutput = current
    }

    /// Builds a new current tap for the app (`TapRoster`). Of the taps it replaces, the newest one that has started
    /// retires until the new one has started, and so does the newest one not noted as started if its processes are
    /// playing right now; the others never started (they aren't playing) and are released at once. The new tap's
    /// start releases every older tap, its failure (while current) releases it and every older tap.
    private func build(_ bundleID: String, key: TapKey, gain: Float) {
        let serial = nextSerial
        nextSerial += 1
        noteStarts(of: bundleID)
        let tap = AppAudioTap(bundleID: bundleID, processes: key.processes, destinationUID: key.destination, gain: gain,
                              onStarted: { [weak self] in
                                  guard let self else { return }
                                  self.releaseTaps(self.roster.started(serial, for: bundleID))
                              },
                              onFailure: { [weak self] _ in
                                  guard let self else { return }
                                  let wasCurrent = self.roster.current(for: bundleID) == serial
                                  self.releaseTaps(self.roster.failed(serial, for: bundleID))
                                  guard wasCurrent else { return }
                                  self.activity[bundleID] = nil
                                  self.failures[bundleID] = key
                                  self.onAppsChanged?()
                              })
        alive[serial] = tap
        // A replaced tap whose start just returned (its app began to play) may not have set `hasStarted` yet: while
        // its processes play right now, it is kept rather than released mid-sound (`TapRoster.install`).
        releaseTaps(roster.install(serial, for: bundleID, isPlaying: { self.alive[$0]?.processesArePlaying() ?? false }))
        activity[bundleID] = TapActivity(now: .now, isPlaying: monitor.apps()[bundleID]?.isPlaying ?? false)
        onAppsChanged?()
    }

    /// Passes on to the roster the starts of the app's taps that have returned but whose `onStarted` report still
    /// waits on the main queue, so a tap that has just begun to play isn't taken for one that never started (and
    /// released while it plays) when it is replaced.
    private func noteStarts(of bundleID: String) {
        let serials = [roster.current(for: bundleID)].compactMap { $0 } + roster.retiring(for: bundleID)
        for serial in serials where alive[serial]?.hasStarted == true {
            releaseTaps(roster.started(serial, for: bundleID))
        }
    }

    /// The app needs no tap: its current tap and every tap it replaced go (a tap released before it got going
    /// reports nothing, so its predecessors can't wait for that).
    private func release(_ bundleID: String) {
        cancelRelease(bundleID)
        let serials = roster.release(bundleID)
        guard !serials.isEmpty else { return }
        activity[bundleID] = nil
        releaseTaps(serials)
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
        let wanted = isRunning && permissionGranted && (panelVisible || !roster.isEmpty || pendingSettings)
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
