import AppKit
import OrbitCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let coordinator: JobCoordinator
    private let registry: FeatureRegistry
    private let showWelcome: () -> Void
    private let navigation = SettingsNavigation()
    private var window: NSWindow?
    private var keyObserver: NSObjectProtocol?

    init(settings: SettingsStore, coordinator: JobCoordinator, registry: FeatureRegistry, showWelcome: @escaping () -> Void) {
        self.settings = settings
        self.coordinator = coordinator
        self.registry = registry
        self.showWelcome = showWelcome
    }

    /// Shows (or re-fronts) the single settings window, on `page` when given (else where it was).
    /// Orbit is an accessory app, so it must activate explicitly for the window to come to the front.
    func show(page: SettingsPage? = nil) {
        if let page { navigation.page = page }
        if window == nil {
            let registry = self.registry
            let dependencies = SettingsDependencies(
                settings: settings,
                suite: registry.context.suite,
                permissions: registry.context.permissions,
                setEnabled: { id, on in registry.setEnabled(id, on) },
                featureSettings: { id in registry.feature(id).makeSettingsView() },
                capabilities: coordinator.capabilities,
                rescan: { [coordinator] in
                    coordinator.rescan()
                    return coordinator.capabilities
                },
                showWelcome: showWelcome)
            let hosting = NSHostingController(rootView: SettingsRootView(navigation: navigation, dependencies: dependencies))
            hosting.sizingOptions = []
            let w = NSWindow(contentViewController: hosting)
            w.title = "Orbit Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.setContentSize(SettingsRootView.defaultSize)
            w.contentMinSize = NSSize(width: 640, height: 420)
            w.isReleasedWhenClosed = false
            // A new autosave name: the old single-page window's saved frame was 560 wide.
            if !w.setFrameUsingName("OrbitSettingsRail") { w.center() }
            w.setFrameAutosaveName("OrbitSettingsRail")
            keyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: w, queue: .main) { [registry] _ in
                MainActor.assumeIsolated { registry.context.permissions.refresh() }
            }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
