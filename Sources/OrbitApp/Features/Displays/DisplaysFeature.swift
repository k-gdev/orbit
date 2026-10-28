import AppKit
import OrbitCore
import SwiftUI

/// Displays (spec §5.3), the BetterDisplay replacement: per display a resolution pop-up (every mode macOS
/// offers, HiDPI included) and a brightness pill: DisplayServices for the built-in panel, DDC/CI over
/// IOAVService for external monitors on Apple Silicon (with boost past 100 up to what each monitor takes),
/// and gamma dimming for monitors that don't answer DDC. Link brightness moves them all together.
///
/// Off, it does nothing at all. On, it only listens for display changes (to re-apply software dimming, which
/// macOS resets) and wake (to re-match DDC services) until the tab is shown; DDC is spoken only while the
/// tab is visible, a pill moves, or a retry the tab started is due.
@MainActor
final class DisplaysFeature: SuiteFeature {
    let id = FeatureID.displays
    private let context: SuiteContext
    private let settings: DisplaySettings
    private var model: DisplaysModel?
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var isRunning = false
    private var isPanelVisible = false

    init(context: SuiteContext) {
        self.context = context
        self.settings = DisplaySettings(defaults: context.defaults)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        idle = nil
        let model = DisplaysModel(settings: settings, driver: DisplaysDriver())
        self.model = model
        model.applySavedSoftwareDims()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, let model = self.model else { return }
            model.displaysChanged(refreshTiles: self.isPanelVisible)
        }
        // The Mac or its screens woke: re-match DDC services (the DCP may have rebuilt them), re-apply gamma
        // and ask silent displays again. Both notifications usually arrive together; one pass, a moment
        // later, once the displays are back.
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { [weak self] in self?.scheduleWakeHandling() }
        }
    }

    private var wakeWork: DispatchWorkItem?
    static let wakeDelay: TimeInterval = 1.5

    private func scheduleWakeHandling() {
        wakeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.wakeWork = nil
                self.model?.systemWoke(refreshTiles: self.isPanelVisible)
            }
        }
        wakeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeDelay, execute: work)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        wakeWork?.cancel()
        wakeWork = nil
        model?.stop()
        model = nil
        isPanelVisible = false
    }

    func panelDidAppear() {
        isPanelVisible = true
        model?.refresh()
    }

    func panelDidDisappear() {
        isPanelVisible = false
        model?.endEditing()
    }

    func makePanelView() -> AnyView {
        AnyView(DisplaysPanelView(model: model ?? idleModel()))
    }

    /// The view refreshes its model when it appears (`refreshForSettings`), never while it's being built.
    func makeSettingsView() -> AnyView {
        AnyView(DisplaysSettingsView(model: model ?? idleModel()))
    }

    static func snapshotViews() -> FeatureSnapshotViews {
        let model = DisplaysFixtures.model()
        return FeatureSnapshotViews(panel: DisplaysPanelView(model: model), settings: DisplaysSettingsView(model: model))
    }

    private var idle: DisplaysModel?

    /// While the feature is off: a model with no driver that lists the connected displays for Settings when
    /// the page appears (no DDC, no writes), on the real settings. Kept until the feature starts.
    private func idleModel() -> DisplaysModel {
        if let idle { return idle }
        let model = DisplaysModel(settings: settings, driver: nil, readsCatalogWhenIdle: true)
        idle = model
        return model
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, token))
    }
}
