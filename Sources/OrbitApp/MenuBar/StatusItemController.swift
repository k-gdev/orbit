import AppKit
import Combine
import OrbitCore

@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: SettingsStore
    private let wheel: WheelController
    private let coordinator: JobCoordinator
    private let windowController: WheelWindowController
    private let showSettings: () -> Void
    private var debugItem: NSMenuItem?
    private var enabledItem: NSMenuItem?
    private var recentItem: NSMenuItem?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, coordinator: JobCoordinator, wheel: WheelController,
         windowController: WheelWindowController, showSettings: @escaping () -> Void) {
        self.windowController = windowController
        self.showSettings = showSettings
        self.settings = settings
        self.coordinator = coordinator
        self.wheel = wheel
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setIcon(busy: false)
        coordinator.$activeJobCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.setIcon(busy: count > 0) }
            .store(in: &cancellables)
        statusItem.menu = makeMenu()
    }

    /// The ringed-planet glyph; its ring is dashed while a job runs.
    private func setIcon(busy: Bool) {
        statusItem.button?.image = OrbitGlyph.image(busy: busy)
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let about = NSMenuItem(title: "About Orbit", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let openFiles = NSMenuItem(title: "Open Files…", action: #selector(openFiles), keyEquivalent: "o")
        openFiles.target = self
        menu.addItem(openFiles)
        let prefs = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        menu.addItem(enabled)
        enabledItem = enabled
        let recent = NSMenuItem(title: "Recent results", action: nil, keyEquivalent: "")
        recent.submenu = NSMenu(title: "Recent results")
        menu.addItem(recent)
        recentItem = recent
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
        let rescan = NSMenuItem(title: "Rescan Helpers", action: #selector(rescanHelpers), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)
        return menu
    }

    /// The Debug submenu appears only when ⌥ is held as the menu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        debugItem?.isHidden = !NSEvent.modifierFlags.contains(.option)
        enabledItem?.state = settings.isEnabled ? .on : .off
        rebuildRecents()
    }

    private func rebuildRecents() {
        guard let submenu = recentItem?.submenu else { return }
        submenu.removeAllItems()
        let entries = coordinator.recents.entries
        if entries.isEmpty {
            let none = NSMenuItem(title: "No recent results", action: nil, keyEquivalent: "")
            none.isEnabled = false
            submenu.addItem(none)
            return
        }
        for entry in entries {
            let item = NSMenuItem(title: entry.title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            submenu.addItem(item)
        }
    }

    @objc private func toggleEnabled() {
        settings.isEnabled.toggle()
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let entry = coordinator.recents.entries.first(where: { $0.id == id }) else { return }
        coordinator.openRecent(entry)
    }

    @objc private func rescanHelpers() {
        coordinator.rescan()
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

    @objc private func openFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "Open in Orbit"
        NSApp.activate()
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        // Let the open panel finish closing before the wheel takes the key window.
        DispatchQueue.main.async { [windowController] in
            guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
            let frame = screen.visibleFrame
            windowController.show(items: urls.map(DroppedItem.init(url:)), at: CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        showSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
