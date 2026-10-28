import AppKit
import Combine
import OrbitCore

/// What one Quick Toggles button shows under its title.
enum QuickToggleDisplay: Equatable {
    case on(String), off(String), action(String), unavailable(String)

    var isOn: Bool { if case .on = self { true } else { false } }
    var isAvailable: Bool { if case .unavailable = self { false } else { true } }
    var subtitle: String {
        switch self {
        case .on(let s), .off(let s), .action(let s), .unavailable(let s): s
        }
    }
}

/// An app Keep Awake can follow ("While Xcode runs").
struct RunningAppChoice: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID }
}

/// The Controls tab's state and actions, shared by the panel and the Settings page. The live model reads
/// the system through `QuickToggleService`; the fixture (snapshots) has no service and only flips its
/// own state, so it never touches the machine.
@MainActor
final class ControlsModel: ObservableObject {
    let settings: ControlsSettings
    let micMute: MicMuteService
    let keepAwake: KeepAwakeController

    @Published private(set) var values: [QuickToggleID: PreferenceValue] = [:]
    @Published private(set) var unavailable: [QuickToggleID: String] = [:]
    @Published private(set) var busy: Set<QuickToggleID> = []
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published var confirmingEject = false
    @Published private(set) var runningApps: [RunningAppChoice] = []
    @Published private(set) var screenRecordingGranted = false
    /// Why the Grab Text shortcut couldn't be registered ("In use by another app"), or nil.
    @Published var shortcutProblem: String?
    /// The user's Shortcuts, for the Do Not Disturb picker (loaded when Settings shows it).
    @Published private(set) var shortcuts: [String] = []

    private let service: QuickToggleService?
    private var forwarders: Set<AnyCancellable> = []
    private var liveObservers: [(NotificationCenter, NSObjectProtocol)] = []

    var showToast: (ToastContent) -> Void = { _ in }
    var grabText: () -> Void = {}
    var openSettings: () -> Void = {}
    var permissionGranted: () -> Bool = { false }

    init(settings: ControlsSettings, micMute: MicMuteService, keepAwake: KeepAwakeController, service: QuickToggleService?) {
        self.settings = settings
        self.micMute = micMute
        self.keepAwake = keepAwake
        self.service = service
        // One observable for the views: re-render when any part changes.
        for publisher in [settings.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          micMute.objectWillChange.map { _ in () }.eraseToAnyPublisher(),
                          keepAwake.objectWillChange.map { _ in () }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in self?.objectWillChange.send() }.store(in: &forwarders)
        }
    }

    /// A model over fixed state for snapshots.
    static func fixture(settings: ControlsSettings, micMute: MicMuteService, keepAwake: KeepAwakeController,
                        values: [QuickToggleID: PreferenceValue], volumes: [VolumeInfo], runningApps: [RunningAppChoice],
                        shortcuts: [String], screenRecordingGranted: Bool) -> ControlsModel {
        let model = ControlsModel(settings: settings, micMute: micMute, keepAwake: keepAwake, service: nil)
        model.values = values
        model.volumes = volumes
        model.runningApps = runningApps
        model.shortcuts = shortcuts
        model.screenRecordingGranted = screenRecordingGranted
        return model
    }

    // MARK: Reading

    /// Re-reads every visible toggle, the drives, the running apps and Screen Recording. Panel open only.
    func refresh() {
        guard let service else { return }
        for id in [QuickToggleID.darkMode, .hideDesktopIcons, .showHiddenFiles, .nightShift] {
            refresh(id, with: service)
        }
        volumes = VolumeLister.ejectable()
        if volumes.isEmpty { confirmingEject = false }
        runningApps = Self.readRunningApps()
        screenRecordingGranted = permissionGranted()
    }

    private func refresh(_ id: QuickToggleID, with service: QuickToggleService) {
        if let reason = service.unavailableReason(id) {
            unavailable[id] = reason
            values[id] = nil
        } else {
            unavailable[id] = nil
            values[id] = service.read(id)
        }
    }

    /// While the panel is open: follow appearance changes, drives coming and going, apps launching and
    /// quitting. Removed again by `endLiveUpdates()`.
    func beginLiveUpdates() {
        guard service != nil, liveObservers.isEmpty else { return }
        let distributed = DistributedNotificationCenter.default()
        liveObservers.append((distributed, distributed.addObserver(forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
                                                                   object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }))
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            liveObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            }))
        }
    }

    func endLiveUpdates() {
        for (center, observer) in liveObservers { center.removeObserver(observer) }
        liveObservers.removeAll()
        confirmingEject = false
    }

    private static func readRunningApps() -> [RunningAppChoice] {
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> RunningAppChoice? in
                guard let id = app.bundleIdentifier, id != me, seen.insert(id).inserted else { return nil }
                return RunningAppChoice(bundleID: id, name: app.localizedName ?? KeepAwakeMode.fallbackAppName(for: id))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    // MARK: What each button shows

    func display(_ id: QuickToggleID) -> QuickToggleDisplay {
        if let reason = unavailable[id] { return .unavailable(reason) }
        switch id {
        case .darkMode, .nightShift:
            guard let value = values[id] else { return .unavailable("Not available") }
            return id.isOn(value) ? .on("On") : .off("Off")
        case .hideDesktopIcons:
            guard let value = values[id] else { return .unavailable("Not available") }
            return id.isOn(value) ? .on("Icons hidden") : .off("Icons shown")
        case .showHiddenFiles:
            guard let value = values[id] else { return .unavailable("Not available") }
            return id.isOn(value) ? .on("Shown in Finder") : .off("Not shown")
        case .doNotDisturb:
            return settings.focusShortcutName == nil ? .action("Choose a Shortcut") : .action("Runs your Shortcut")
        case .ejectDrives:
            switch volumes.count {
            case 0: return .unavailable("No drives")
            case 1: return .action(volumes[0].name)
            default: return .action("\(volumes.count) drives")
            }
        case .micMute:
            guard micMute.isAvailable else { return .unavailable("No microphone") }
            return micMute.isMuted ? .on("Muted") : .off("Mic on")
        }
    }

    // MARK: Actions

    /// A Quick Toggles button was clicked.
    func activate(_ id: QuickToggleID) {
        guard !busy.contains(id) else { return }
        switch id {
        case .micMute:
            micMute.toggle()
        case .doNotDisturb:
            runFocusShortcut()
        case .ejectDrives:
            confirmingEject = !volumes.isEmpty && !confirmingEject
        case .darkMode, .hideDesktopIcons, .showHiddenFiles, .nightShift:
            setToggle(id, on: !display(id).isOn)
        }
    }

    /// Turns a setting toggle on or off, recording (or restoring) its previous state.
    private func setToggle(_ id: QuickToggleID, on: Bool) {
        guard let service else {
            values[id] = on ? (id == .hideDesktopIcons ? .bool(false) : .bool(true)) : .absent
            return
        }
        guard let current = service.read(id) else { return }
        var book = settings.restoreBook
        let target = on ? book.turnOn(id, current: current) : book.turnOff(id, current: current)
        guard target != current else {
            settings.restoreBook = book
            refresh(id, with: service)
            return
        }
        busy.insert(id)
        Task {
            do {
                try await service.write(id, target)
                settings.restoreBook = book
            } catch {
                Log.error("quick toggle \(id.rawValue) failed: \(error.localizedDescription)")
                showToast(ToastContent(message: "\(id.title) didn’t change", detail: error.localizedDescription, isError: true))
            }
            busy.remove(id)
            refresh(id, with: service)
        }
    }

    private func runFocusShortcut() {
        guard let name = settings.focusShortcutName else {
            openSettings()
            return
        }
        guard service != nil else { return }
        busy.insert(.doNotDisturb)
        Task {
            do {
                try await ShortcutsRunner.run(name)
                showToast(ToastContent(message: "Ran “\(name)”"))
            } catch {
                showToast(ToastContent(message: "“\(name)” didn’t run", detail: "Check the Shortcut in the Shortcuts app.", isError: true))
            }
            busy.remove(.doNotDisturb)
        }
    }

    /// The in-panel confirmation's Eject button.
    func confirmEject() {
        let targets = volumes
        confirmingEject = false
        guard service != nil, !targets.isEmpty else { return }
        busy.insert(.ejectDrives)
        Task {
            let result = await VolumeLister.eject(targets)
            busy.remove(.ejectDrives)
            volumes = VolumeLister.ejectable()
            showToast(ToastContent(message: EjectableVolumeFilter.summary(ejected: result.ejected, failed: result.failed),
                                   detail: result.failed.isEmpty ? nil : "Quit the apps using it and try again.",
                                   isError: !result.failed.isEmpty))
        }
    }

    /// Loads the user's Shortcuts for the Do Not Disturb picker.
    func loadShortcuts() async {
        guard service != nil else { return }
        shortcuts = await ShortcutsRunner.list()
    }
}
