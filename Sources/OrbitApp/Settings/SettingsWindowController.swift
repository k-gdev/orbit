import AppKit
import OrbitCore
import SwiftUI

@MainActor
final class SettingsWindowController {
    private let settings: SettingsStore
    private let coordinator: JobCoordinator
    private var window: NSWindow?

    init(settings: SettingsStore, coordinator: JobCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    /// Shows (or re-fronts) the single settings window. Orbit is an accessory app,
    /// so it must activate explicitly for the window to come to the front.
    func show() {
        if window == nil {
            let view = SettingsView(settings: settings,
                                    capabilities: coordinator.capabilities,
                                    rescan: { [coordinator] in
                                        coordinator.rescan()
                                        return coordinator.capabilities
                                    })
            let hosting = NSHostingController(rootView: view)
            let w = NSWindow(contentViewController: hosting)
            w.title = "Orbit Settings"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.setContentSize(NSSize(width: 560, height: 640))
            w.contentMinSize = NSSize(width: 520, height: 400)
            w.isReleasedWhenClosed = false
            if !w.setFrameUsingName("OrbitSettings") { w.center() }
            w.setFrameAutosaveName("OrbitSettings")
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
