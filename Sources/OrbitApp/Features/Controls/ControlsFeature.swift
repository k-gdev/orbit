import Combine
import OrbitCore
import SwiftUI

/// Controls (spec §8): Keep Awake, Quick Toggles and Grab Text, in the last tab.
///
/// While on: the Grab Text shortcut is registered (hot key `controls.grabText`). Everything else waits
/// for the user: Keep Awake holds a power assertion only while a session runs (and puts the dot on
/// Orbit's icon), toggle states are read only while the tab is open, and Screen Recording is asked for
/// the first time Grab Text runs. `stop()` ends Keep Awake (releasing its assertions), unregisters the
/// shortcut, closes the crosshair and clears the indicator. Quick toggles are system settings the user
/// chose, so they stay as set; the shared mic mute is restored by `MicMuteService` itself.
@MainActor
final class ControlsFeature: SuiteFeature {
    let id = FeatureID.controls
    static let grabTextHotKeyID = "controls.grabText"
    static let indicatorID = "controls.keepAwake"

    private let context: SuiteContext
    private let settings: ControlsSettings
    private let model: ControlsModel
    private let keepAwake: KeepAwakeController
    private let grabText: GrabTextController
    private var isRunning = false
    private var shortcutSubscription: AnyCancellable?

    init(context: SuiteContext) {
        self.context = context
        settings = ControlsSettings(defaults: context.defaults)
        keepAwake = KeepAwakeController(settings: settings)
        grabText = GrabTextController(context: context)
        model = ControlsModel(settings: settings, micMute: context.micMute, keepAwake: keepAwake, service: QuickToggleService())
        keepAwake.onActiveChange = { [weak context] active in context?.setStatusIndicator(Self.indicatorID, active: active) }
        keepAwake.onMessage = { [weak context] content in context?.toasts.show(content) }
        model.showToast = { [weak context] content in context?.toasts.show(content) }
        model.grabText = { [weak self] in self?.grabText.begin() }
        model.openSettings = { [weak context] in
            context?.closePanel()
            context?.openSettings(.feature(.controls))
        }
        model.permissionGranted = { [weak context] in context?.permissions.status(.screenRecording) == .granted }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        registerShortcut()
        shortcutSubscription = settings.$grabTextShortcut.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.registerShortcut() }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        shortcutSubscription = nil
        context.hotKeys.unregister(id: Self.grabTextHotKeyID)
        model.shortcutProblem = nil
        grabText.cancel()
        model.endLiveUpdates()
        keepAwake.stop()
        context.setStatusIndicator(Self.indicatorID, active: false)
    }

    func panelDidAppear() {
        model.refresh()
        model.beginLiveUpdates()
    }

    func panelDidDisappear() {
        model.endLiveUpdates()
    }

    func makePanelView() -> AnyView { AnyView(ControlsPanelView(model: model)) }

    func makeSettingsView() -> AnyView {
        AnyView(ControlsSettingsView(model: model, micMuteSettings: context.micMute.settings))
    }

    /// Registers the Grab Text shortcut, or explains in Settings why it couldn't be (TextSniper still
    /// running with ⇧⌘2, or another Orbit shortcut).
    private func registerShortcut() {
        guard isRunning else { return }
        let combo = settings.grabTextShortcut
        if context.hotKeys.register(combo, id: Self.grabTextHotKeyID, action: { [weak self] in self?.grabText.begin() }) {
            model.shortcutProblem = nil
        } else if let owner = context.hotKeys.owner(of: combo), owner != Self.grabTextHotKeyID {
            model.shortcutProblem = "Already used by \(Self.ownerName(owner))"
        } else {
            model.shortcutProblem = "In use by another app"
            Log.info("grab text shortcut \(combo.display) is taken")
        }
    }

    private static func ownerName(_ id: String) -> String {
        if id == MicMuteService.hotKeyID { return "Mute microphone" }
        let prefix = id.split(separator: ".").first.map(String.init) ?? id
        return FeatureID(rawValue: prefix)?.title ?? id
    }

    // MARK: Snapshots

    static func snapshotViews() -> FeatureSnapshotViews {
        let model = fixtureModel()
        return FeatureSnapshotViews(panel: ControlsPanelView(model: model),
                                    settings: ControlsSettingsView(model: model, micMuteSettings: model.micMute.settings))
    }

    /// A realistic tab with no hardware access: Keep Awake 48 minutes into two hours with the display on,
    /// dark mode on, one external drive, a Focus Shortcut chosen. Settings come from the registration
    /// domain of a throwaway absolute-path suite, so nothing is ever written.
    private static func fixtureModel() -> ControlsModel {
        let path = FileManager.default.temporaryDirectory.appending(path: "orbit-controls-fixture-\(UUID().uuidString).plist").path
        guard let defaults = UserDefaults(suiteName: path) else { preconditionFailure("ControlsFeature: no throwaway defaults suite") }
        defaults.register(defaults: [
            "controls.focusShortcutName": "Toggle Do Not Disturb",
            "controls.keepDisplayAwake": true,
        ])
        let settings = ControlsSettings(defaults: defaults)
        let session = KeepAwakeSession(startDate: Date().addingTimeInterval(-48 * 60), mode: .duration(2 * 3600), keepDisplayAwake: true)
        let keepAwake = KeepAwakeController.fixture(settings: settings, session: session)
        return ControlsModel.fixture(
            settings: settings, micMute: .fixture(muted: false, available: true), keepAwake: keepAwake,
            values: [.darkMode: .bool(true), .hideDesktopIcons: .absent, .showHiddenFiles: .absent, .nightShift: .bool(false)],
            volumes: [VolumeInfo(path: "/Volumes/Backup SSD", name: "Backup SSD", isInternal: false, isRemovable: false,
                                 isEjectable: true, isLocal: true, isRootFileSystem: false, isBrowsable: true)],
            runningApps: [RunningAppChoice(bundleID: "com.apple.dt.Xcode", name: "Xcode"),
                          RunningAppChoice(bundleID: "com.apple.Safari", name: "Safari")],
            shortcuts: ["Send Message", "Toggle Do Not Disturb"],
            screenRecordingGranted: false)
    }
}
