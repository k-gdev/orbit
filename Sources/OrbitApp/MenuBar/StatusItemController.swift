import AppKit
import OrbitCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: SettingsStore
    private let wheel: WheelController
    private var debugItem: NSMenuItem?

    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        wheel = WheelController(settings: settings)
        super.init()
        Haptics.settings = settings
        wheel.onSelect = { slice, _ in
            Log.info("selected \(slice.id)") // Task 10 routes this to the job coordinator.
        }
        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Orbit")
            image?.isTemplate = true
            button.image = image
        }
        statusItem.menu = makeMenu()
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let about = NSMenuItem(title: "About Orbit", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        let debug = NSMenuItem(title: "Debug", action: nil, keyEquivalent: "")
        debug.submenu = makeDebugMenu()
        debug.isHidden = true
        menu.addItem(debug)
        debugItem = debug
        let quit = NSMenuItem(title: "Quit Orbit", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    private func makeDebugMenu() -> NSMenu {
        let menu = NSMenu(title: "Debug")
        let showWheel = NSMenuItem(title: "Show Wheel for File…", action: #selector(showWheelForFile), keyEquivalent: "")
        showWheel.target = self
        menu.addItem(showWheel)
        return menu
    }

    /// The Debug submenu appears only when ⌥ is held as the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        debugItem?.isHidden = !NSEvent.modifierFlags.contains(.option)
    }

    @objc private func showWheelForFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Show Wheel"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let items = panel.urls.map(DroppedItem.init(url:))
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        wheel.showDebug(kind: .convert, items: items, at: CGPoint(x: frame.midX, y: frame.midY))
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
