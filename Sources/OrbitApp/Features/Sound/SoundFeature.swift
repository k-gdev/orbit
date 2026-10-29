import AppKit
import Combine
import OrbitCore
import SwiftUI

/// Sound (spec §5.1): output, alerts and microphone devices, the master volume and input level, the shared
/// mic mute, and a per-app mixer (0–150 % and per-app output through Core Audio process taps, macOS 14.2+).
///
/// - `init` only loads settings.
/// - `start()` begins listening to the audio hardware, starts `SoundEngine` (taps, only with System Audio
///   Recording granted; the grant is picked up whenever it arrives) and the preferred-mic watcher.
/// - `stop()` (feature off, or quitting through `FeatureRegistry.stopAll()`) releases every tap and
///   aggregate device and waits for that, then removes every listener.
/// - The process list is read only while the Sound tab is visible, a tap exists, or an app has settings
///   waiting for it (`SoundEngine`).
@MainActor
final class SoundFeature: SuiteFeature, SoundPanelActions {
    let id = FeatureID.sound
    private let context: SuiteContext
    let settings: SoundSettings
    private let hardware = AudioHardware()
    private let directory = SoundAppDirectory()
    private lazy var model: SoundPanelModel = {
        let model = SoundPanelModel(settings: settings, micMute: context.micMute)
        model.hardware = self
        return model
    }()
    /// The `SoundEngine` (macOS 14.2+), stored untyped so this class builds for 14.0.
    private var engineBox: AnyObject?
    private var micWatcher: PreferredMicWatcher?
    private var subscriptions: Set<AnyCancellable> = []
    private var isRunning = false
    private var panelVisible = false
    private var refreshScheduled = false

    init(context: SuiteContext) {
        self.context = context
        settings = SoundSettings(defaults: context.defaults)
    }

    @available(macOS 14.2, *)
    private var engine: SoundEngine? { engineBox as? SoundEngine }

    private var audioPermissionGranted: Bool {
        context.permissions.status(.systemAudioRecording) == .granted
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        hardware.start()
        let watcher = PreferredMicWatcher(settings: settings, hardware: hardware)
        watcher.start()
        micWatcher = watcher
        if #available(macOS 14.2, *) {
            let engine = SoundEngine(settings: settings, hardware: hardware)
            engine.onAppsChanged = { [weak self] in self?.scheduleRefresh() }
            engine.permissionGranted = audioPermissionGranted
            engine.panelVisible = panelVisible
            engineBox = engine
            engine.start()
        }
        // Permission may be granted after start (the prompt from turning Sound on, or System Settings).
        context.permissions.$statuses.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.permissionsChanged() }
        }.store(in: &subscriptions)
        hardware.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        settings.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        permissionsChanged()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        settings.persistAppStates()
        subscriptions.removeAll()
        if #available(macOS 14.2, *) { engine?.stop() }
        engineBox = nil
        micWatcher?.stop()
        micWatcher = nil
        hardware.stop()
    }

    func panelDidAppear() {
        panelVisible = true
        context.permissions.refresh()
        if #available(macOS 14.2, *) { engine?.panelVisible = true }
        hardware.refreshDevices()
        refreshNow()
    }

    func panelDidDisappear() {
        panelVisible = false
        settings.persistAppStates()   // in case a drag didn't report its end
        if #available(macOS 14.2, *) { engine?.panelVisible = false }
    }

    private func permissionsChanged() {
        guard isRunning else { return }
        if #available(macOS 14.2, *) { engine?.permissionGranted = audioPermissionGranted }
        scheduleRefresh()
    }

    // MARK: Model

    private func scheduleRefresh() {
        guard isRunning, panelVisible, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in self?.refreshNow() }
    }

    private func refreshNow() {
        refreshScheduled = false
        refreshDevices()
        refreshApps()
    }

    private func refreshDevices() {
        let summaries = hardware.devices.map(\.summary)
        let names = AudioDeviceNaming.displayNames(for: summaries)
        let outputs = summaries.filter(\.hasOutput).map { SoundDeviceItem(uid: $0.uid, name: names[$0.uid] ?? $0.name, symbol: $0.symbol(forInput: false)) }
        let inputs = summaries.filter(\.hasInput).map { SoundDeviceItem(uid: $0.uid, name: names[$0.uid] ?? $0.name, symbol: $0.symbol(forInput: true)) }
        if model.outputs != outputs { model.outputs = outputs }
        if model.inputs != inputs { model.inputs = inputs }
        if model.defaultOutputUID != hardware.defaultOutputUID { model.defaultOutputUID = hardware.defaultOutputUID }
        if model.systemOutputUID != hardware.systemOutputUID { model.systemOutputUID = hardware.systemOutputUID }
        if model.defaultInputUID != hardware.defaultInputUID { model.defaultInputUID = hardware.defaultInputUID }
        let outputVolume = hardware.outputVolume.map { (Double($0) * 100).rounded() }
        let inputVolume = hardware.inputVolume.map { (Double($0) * 100).rounded() }
        if model.outputVolume != outputVolume { model.outputVolume = outputVolume }
        if model.outputMuted != hardware.outputMuted { model.outputMuted = hardware.outputMuted }
        if model.inputVolume != inputVolume { model.inputVolume = inputVolume }
    }

    private func refreshApps() {
        guard #available(macOS 14.2, *) else {
            model.appsStatus = .needsNewerSystem
            model.apps = []
            return
        }
        let status: SoundAppsStatus = audioPermissionGranted ? .available : .needsPermission
        if model.appsStatus != status { model.appsStatus = status }
        guard status == .available, let engine else {
            if !model.apps.isEmpty { model.apps = [] }
            return
        }
        if !engine.monitor.isListening { engine.monitor.refresh() }
        let groups = engine.monitor.apps()
        var identities: [String: SoundAppIdentity] = [:]
        var candidates: [AudioAppCandidate] = []
        for (bundleID, info) in groups {
            let identity = directory.identity(for: bundleID, pid: info.pids.first)
            identities[bundleID] = identity
            candidates.append(AudioAppCandidate(bundleID: bundleID, name: identity.name, isRunning: true, isPlaying: info.isPlaying,
                                                isListable: SoundAppDirectory.isListable(bundleID)))
        }
        for pinned in settings.pinnedBundleIDs where groups[pinned] == nil {
            let identity = directory.identity(for: pinned)
            identities[pinned] = identity
            candidates.append(AudioAppCandidate(bundleID: pinned, name: identity.name, isRunning: false, isPlaying: false, isListable: true))
        }
        let visible = AudioAppList.visible(candidates, pinned: settings.pinnedBundleIDs, customised: Set(settings.appStates.keys),
                                           showAll: settings.showAllApps, excluding: [Bundle.main.bundleIdentifier ?? "com.kevo.orbit"])
        let failed = engine.failedBundleIDs
        model.apps = visible.compactMap { candidate in
            identities[candidate.bundleID].map {
                SoundAppItem(identity: $0, isPlaying: candidate.isPlaying, followedOutputUID: engine.followedOutput(for: candidate.bundleID),
                             tapFailed: failed.contains(candidate.bundleID))
            }
        }
    }

    // MARK: SoundPanelActions (the user's clicks in the Sound tab)

    func selectOutput(_ uid: String) { hardware.setDefaultOutput(uid: uid) }
    func selectSystemOutput(_ uid: String) { hardware.setSystemOutput(uid: uid) }
    func selectInput(_ uid: String) { hardware.setDefaultInput(uid: uid) }
    func setOutputVolume(_ value: Float) { hardware.setOutputVolume(value) }
    func setInputVolume(_ value: Float) { hardware.setInputVolume(value) }
    func requestPermission() { context.permissions.request(.systemAudioRecording) }
    func appsChanged() { scheduleRefresh() }

    // MARK: Views

    func makePanelView() -> AnyView {
        AnyView(SoundPanelView(model: model))
    }

    func makeSettingsView() -> AnyView {
        let hardware = hardware, directory = directory, hotKeys = context.hotKeys
        let environment = SoundSettingsEnvironment(
            inputDevices: {
                // A one-off read when the page opens; Sound may be off.
                let devices = hardware.isRunning ? hardware.devices : SoundHAL.allDevices().compactMap(AudioHardware.describe)
                let summaries = devices.map(\.summary)
                let names = AudioDeviceNaming.displayNames(for: summaries)
                return summaries.filter(\.hasInput).map { SoundDeviceItem(uid: $0.uid, name: names[$0.uid] ?? $0.name, symbol: $0.symbol(forInput: true)) }
            },
            runningApps: { directory.runningApps() },
            identity: { directory.identity(for: $0) },
            conflict: { combo in Self.conflictMessage(owner: hotKeys.owner(of: combo)) })
        return AnyView(SoundSettingsView(settings: settings, micSettings: context.micMute.settings, environment: environment))
    }

    /// "Already used by Clipboard" for another feature's hot key id (`clipboard.popup`); nil for the mic mute's own.
    static func conflictMessage(owner: String?) -> String? {
        guard let owner, owner != MicMuteService.hotKeyID else { return nil }
        let feature = owner.split(separator: ".").first.flatMap { FeatureID(rawValue: String($0)) }
        return "Already used by \(feature?.title ?? owner)"
    }

    /// `ORBIT_SOUND_SNAPSHOT=arctis` in the environment of `Orbit --snapshot-panel sound` draws the headset as the
    /// mic that ignores mute from the Mac (its warning, a "Fixed" level) instead of muted. Only the snapshot CLI reads it.
    static func snapshotViews() -> FeatureSnapshotViews {
        let settings = SoundSettings(defaults: SoundFixtures.throwawayDefaults())
        let ignoresMute = ProcessInfo.processInfo.environment["ORBIT_SOUND_SNAPSHOT"] == "arctis"
        let micMute = ignoresMute ? MicMuteService.fixture(unmutableInputName: "SteelSeries Arctis Nova 5")
                                  : MicMuteService.fixture(muted: true)
        let model = SoundPanelModel.fixture(settings: settings, micMute: micMute)
        if ignoresMute { model.inputVolume = nil }
        let identities = SoundFixtures.apps.map(\.identity)
        let environment = SoundSettingsEnvironment(
            inputDevices: { model.inputs },
            runningApps: { identities },
            identity: { id in identities.first { $0.bundleID == id } ?? SoundAppIdentity(bundleID: id, name: id, icon: .symbol("app.dashed", .gray)) },
            conflict: { _ in nil })
        settings.preferredMicUID = SoundFixtures.headset
        return FeatureSnapshotViews(panel: SoundPanelView(model: model),
                                    settings: SoundSettingsView(settings: settings, micSettings: micMute.settings, environment: environment))
    }
}

extension SoundFixtures {
    /// A defaults suite stored as a plist in its own temp folder (an absolute-path suite name), so snapshots
    /// never read or write the real settings or anything in ~/Library/Preferences.
    static func throwawayDefaults() -> UserDefaults {
        let folder = FileManager.default.temporaryDirectory.appending(path: "orbit-sound-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appending(path: "prefs", directoryHint: .notDirectory).path
        guard let defaults = UserDefaults(suiteName: path) else { preconditionFailure("SoundFixtures: no throwaway defaults suite") }
        return defaults
    }
}
