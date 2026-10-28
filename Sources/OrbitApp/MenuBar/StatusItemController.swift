import AppKit
import Combine
import OrbitCore

/// Orbit's menu bar icon. Left-click toggles the suite panel (`MenuBarPanelController`); right-click or
/// ⌃-click shows the classic menu (About, Open Files…, Settings…, Enabled, Recent results, ⌥ Debug,
/// Quit), unchanged. The icon's ring is dashed while a job runs, and a small accent dot shows while any
/// feature has a status indicator on (`SuiteContext.setStatusIndicator`).
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let settings: SettingsStore
    private let wheel: WheelController
    private let coordinator: JobCoordinator
    private let windowController: WheelWindowController
    private let showSettings: (SettingsPage?) -> Void
    private let panel: MenuBarPanelController
    private var menu: NSMenu?
    private var debugItem: NSMenuItem?
    private var enabledItem: NSMenuItem?
    private var recentItem: NSMenuItem?
    private var indicatorDot: NSView?
    private var cancellables: Set<AnyCancellable> = []

    init(settings: SettingsStore, coordinator: JobCoordinator, wheel: WheelController,
         windowController: WheelWindowController, registry: FeatureRegistry,
         showSettings: @escaping (SettingsPage?) -> Void) {
        self.windowController = windowController
        self.showSettings = showSettings
        self.settings = settings
        self.coordinator = coordinator
        self.wheel = wheel
        panel = MenuBarPanelController(registry: registry, settings: settings)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        setIcon(busy: false)
        coordinator.$activeJobCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.setIcon(busy: count > 0) }
            .store(in: &cancellables)
        menu = makeMenu()
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusButtonClicked)
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
        }
        panel.actions = panelActions()
        panel.onVisibilityChange = { [weak self] open in self?.statusItem.button?.highlight(open) }
        installIndicatorDot()
        registry.context.$statusIndicators
            .receive(on: DispatchQueue.main)
            .sink { [weak self] ids in self?.indicatorDot?.isHidden = ids.isEmpty }
            .store(in: &cancellables)
        settings.$accentHex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hex in self?.colourIndicatorDot(hex: hex) }
            .store(in: &cancellables)
    }

    /// Closes the suite panel if it is open (before Settings or a feature's own window appears).
    func closePanel() {
        panel.close()
    }

    /// The ringed-planet glyph; its ring is dashed while a job runs.
    private func setIcon(busy: Bool) {
        statusItem.button?.image = OrbitGlyph.image(busy: busy)
    }

    // MARK: Clicks

    @objc private func statusButtonClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseDown || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            panel.toggle(from: button)
        }
    }

    /// Pops the classic menu from the status item (attached only for this click, so left-click stays the panel's).
    private func showMenu() {
        panel.close()
        guard let menu else { return }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func panelActions() -> PanelActions {
        PanelActions(
            openSettings: { [weak self] in self?.openSettingsPage(nil) },
            openFeaturesPage: { [weak self] in self?.openSettingsPage(.features) },
            quit: { [weak self] in self?.quit() },
            openFiles: { [weak self] in self?.panel.close(); self?.openFiles() },
            about: { [weak self] in self?.panel.close(); self?.showAbout() },
            recents: { [weak self] in self?.coordinator.recents.entries.map { (id: $0.id, title: $0.title) } ?? [] },
            openRecent: { [weak self] id in
                guard let self, let entry = self.coordinator.recents.entries.first(where: { $0.id == id }) else { return }
                self.panel.close()
                self.coordinator.openRecent(entry)
            })
    }

    private func openSettingsPage(_ page: SettingsPage?) {
        panel.close()
        showSettings(page)
    }

    // MARK: Indicator dot

    /// A 6 pt accent dot at the icon's lower right, over the template glyph (which stays tinted by the system).
    private func installIndicatorDot() {
        guard let button = statusItem.button else { return }
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        dot.layer?.borderWidth = 0.5
        dot.layer?.borderColor = NSColor.black.withAlphaComponent(0.25).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.isHidden = true
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            dot.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            dot.bottomAnchor.constraint(equalTo: button.bottomAnchor, constant: -3),
        ])
        indicatorDot = dot
        colourIndicatorDot(hex: settings.accentHex)
    }

    private func colourIndicatorDot(hex: String) {
        let c = HexColor.parse(hex) ?? HexColor.parse(SettingsStore.defaultAccentHex)!
        indicatorDot?.layer?.backgroundColor = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1).cgColor
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

    @objc func openFiles() {
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

    @objc func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        showSettings(nil)
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }
}
