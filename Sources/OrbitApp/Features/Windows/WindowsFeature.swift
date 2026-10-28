import AppKit
import Combine
import OrbitCore
import SwiftUI

/// Windows (spec §5.4): the Dock preview (hover an open app's Dock icon to see its windows, click one to
/// bring it forward) and the Windows tab (running apps: bring to front, hide, quit, force quit; their
/// windows: bring forward, minimise or restore, close).
///
/// Costs while on: the Dock observer, and only while "Dock preview" is on and Accessibility is granted
/// (`DockPreviewReadiness.watchesDock`); a permission-change listener. The tab reads apps and windows only
/// while it is on screen. Accessibility and Screen Recording usually arrive after `start()` (the user
/// grants them in System Settings), so the feature follows `PermissionCenter` and starts the Dock watcher
/// when Accessibility appears; it never prompts itself (only the registry and the user's "Allow…" clicks
/// go through `PermissionCenter.request`). `stop()` releases everything.
@MainActor
final class WindowsFeature: SuiteFeature {
    let id = FeatureID.windows
    let settings: WindowsSettings

    private let context: SuiteContext
    private var isRunning = false
    private var subscriptions: Set<AnyCancellable> = []
    private var accessibilityObserver: NSObjectProtocol?
    private var dockPreview: DockPreviewController?
    private var appControl: AppControlService?
    private var panelModel: WindowsPanelModel?

    init(context: SuiteContext) {
        self.context = context
        settings = WindowsSettings(defaults: context.defaults)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        context.permissions.$statuses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDockPreview() }
            .store(in: &subscriptions)
        settings.$dockPreviewEnabled
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateDockPreview() }
            .store(in: &subscriptions)
        // macOS posts this whenever an app's Accessibility permission changes; re-read so a grant made in
        // System Settings starts the Dock preview without waiting for Orbit to become active.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.context.permissions.refresh() }
            }
        }
        updateDockPreview()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        subscriptions.removeAll()
        if let accessibilityObserver { DistributedNotificationCenter.default().removeObserver(accessibilityObserver) }
        accessibilityObserver = nil
        dockPreview?.stop()
        dockPreview = nil
        panelModel?.disappear()
        panelModel = nil
        appControl = nil
    }

    func panelDidAppear() {
        liveModel().appear()
    }

    func panelDidDisappear() {
        panelModel?.disappear()
    }

    func makePanelView() -> AnyView {
        AnyView(WindowsPanelView(model: liveModel()))
    }

    func makeSettingsView() -> AnyView {
        AnyView(WindowsSettingsView(settings: settings, permissions: context.permissions))
    }

    static func snapshotViews() -> FeatureSnapshotViews {
        let settings = WindowsSettings(defaults: WindowsFixtures.defaults())
        // The same permission state as the Settings snapshot's header: Accessibility yes, Screen Recording no.
        let permissions = PermissionCenter(live: false, fixed: [.accessibility: .granted, .screenRecording: .notGranted])
        return FeatureSnapshotViews(panel: WindowsPanelView(model: WindowsFixtures.panelModel(.granted)),
                                    settings: WindowsSettingsView(settings: settings, permissions: permissions))
    }

    // MARK: Internals

    /// The tab's model, made on first use and kept while the feature runs.
    private func liveModel() -> WindowsPanelModel {
        if let panelModel { return panelModel }
        let control = appControl ?? AppControlService()
        appControl = control
        let model = WindowsPanelModel(live: .init(control: control, settings: settings, permissions: context.permissions,
                                                  closePanel: { [weak self] in self?.context.closePanel() }))
        panelModel = model
        return model
    }

    /// Runs the Dock preview exactly when it can and should: feature on, "Dock preview" on, Accessibility granted.
    private func updateDockPreview() {
        let readiness = DockPreviewReadiness(enabled: settings.dockPreviewEnabled,
                                             accessibility: context.permissions.status(.accessibility) == .granted,
                                             screenRecording: context.permissions.status(.screenRecording) == .granted)
        let wanted = isRunning && readiness.watchesDock
        if wanted, dockPreview == nil {
            let controller = DockPreviewController(settings: settings)
            controller.start()
            dockPreview = controller
            Log.info("windows: Dock preview on (\(readiness))")
        } else if !wanted, let controller = dockPreview {
            controller.stop()
            dockPreview = nil
            Log.info("windows: Dock preview off (\(readiness))")
        }
    }
}
