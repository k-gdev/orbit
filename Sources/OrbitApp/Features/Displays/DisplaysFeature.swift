import AppKit
import OrbitCore
import SwiftUI

/// Displays (spec §5.3), the BetterDisplay replacement: per display a resolution pop-up (every mode macOS
/// offers, HiDPI included) and a brightness pill: DisplayServices for the built-in panel, DDC/CI over
/// IOAVService for external monitors on Apple Silicon (with boost past 100 up to what each monitor takes),
/// and gamma dimming for monitors that don't answer DDC. Link brightness moves them all together.
///
/// Off, it does nothing at all. On, it only listens for display changes (to re-apply software dimming, which
/// macOS resets) until the tab is shown; DDC is spoken only while the tab is visible or a pill moves.
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
        let model = DisplaysModel(settings: settings, driver: DisplaysDriver())
        self.model = model
        model.applySavedSoftwareDims()
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            guard let self, let model = self.model else { return }
            model.displaysChanged(refreshTiles: self.isPanelVisible)
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.screensDidWakeNotification) { [weak self] in
            self?.model?.screensWoke()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
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

    func makeSettingsView() -> AnyView {
        if let model {
            model.refresh()
            return AnyView(DisplaysSettingsView(model: model))
        }
        return AnyView(DisplaysSettingsView(model: idleModel()))
    }

    static func snapshotViews() -> FeatureSnapshotViews {
        let model = DisplaysFixtures.model()
        return FeatureSnapshotViews(panel: DisplaysPanelView(model: model), settings: DisplaysSettingsView(model: model))
    }

    /// While the feature is off: the connected displays for Settings (no DDC, no writes), on the real settings.
    private func idleModel() -> DisplaysModel {
        let tiles = DisplayCatalog.scan().map { info in
            DisplaysModel.Tile(id: info.id, key: info.key, title: info.title, isBuiltIn: info.isBuiltIn,
                               control: BuiltInBrightness.canControl(info.id) ? .native(builtIn: info.isBuiltIn) : .probing,
                               reading: nil, brightness: 100, modes: info.modes)
        }
        return DisplaysModel(settings: settings, driver: nil, tiles: tiles)
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ handler: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { handler() }
        }
        observers.append((center, token))
    }
}
