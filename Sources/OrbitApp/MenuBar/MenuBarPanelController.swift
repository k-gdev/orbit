import AppKit
import Combine
import OrbitCore
import SwiftUI

/// Shows and hides the menu bar panel, keeps its tabs in step with the enabled features, and tells the
/// visible feature when its tab appears and disappears. Event monitors exist only while the panel is open.
@MainActor
final class MenuBarPanelController {
    private let registry: FeatureRegistry
    private let settings: SettingsStore
    private let model = PanelModel()
    private var panel: MenuBarPanel?
    private var anchor: NSStatusBarButton?
    private var monitors: [Any] = []
    /// Notification observers that exist while the panel is open, with the center each was added to.
    private var observers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    /// The last mouse-down inside the panel (see `MenuBarPanelDismissal`).
    private var lastPanelClick: Date?
    private var subscriptions: Set<AnyCancellable> = []
    /// The feature whose `panelDidAppear()` ran without a matching `panelDidDisappear()`.
    private var appeared: FeatureID?

    /// What the footer buttons do; set by `StatusItemController` before the first `show`.
    var actions = PanelActions()
    /// Called when the panel opens (true) or closes (false), for the status button's highlight.
    var onVisibilityChange: (Bool) -> Void = { _ in }

    /// Space reserved for the tab row, footer and margins when sizing the content area.
    private static let chromeHeight: CGFloat = 140

    init(registry: FeatureRegistry, settings: SettingsStore) {
        self.registry = registry
        self.settings = settings
        model.pageProvider = { [registry] id in
            let feature = registry.feature(id)
            return (feature.makePanelView(), type(of: feature).managesOwnScrolling)
        }
        model.onSelectionChange = { [weak self] old, new in self?.selectionChanged(from: old, to: new) }
        registry.context.suite.$enabledFeatures
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refreshTabs() }
            .store(in: &subscriptions)
    }

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(from button: NSStatusBarButton) {
        if isOpen { close() } else { show(from: button) }
    }

    func show(from button: NSStatusBarButton) {
        anchor = button
        // The panel never activates Orbit, so grants made in System Settings since the last look are
        // picked up here, before the visible feature's panelDidAppear().
        registry.context.permissions.refresh()
        let screen = button.window?.screen ?? NSScreen.main
        model.contentMaxHeight = Self.contentMaxHeight(for: screen)
        model.update(tabs: registry.enabledInOrder, preferred: registry.context.suite.lastTab)
        let panel = self.panel ?? makePanel()
        self.panel = panel
        place(panel)
        panel.makeKeyAndOrderFront(nil)
        installMonitors()
        appear(model.selected)
        onVisibilityChange(true)
    }

    func close() {
        guard let panel, panel.isVisible else { return }
        removeMonitors()
        appear(nil)
        panel.orderOut(nil)
        model.clearPage()
        onVisibilityChange(false)
    }

    // MARK: Panel

    private func makePanel() -> MenuBarPanel {
        let root = PanelView(model: model, settings: settings, actions: actions)
        let host = PanelHostingView(rootView: root)
        let panel = MenuBarPanel(contentView: host)
        panel.onCancel = { [weak self] in self?.close() }
        host.onSizeChange = { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            self.place(panel)
        }
        return panel
    }

    /// Centred under the status button, top just below the menu bar, kept inside the visible frame.
    private func place(_ panel: MenuBarPanel) {
        guard let host = panel.contentView else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = anchor?.window?.screen ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let buttonFrame = anchor.flatMap { button in button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) } }
        let midX = buttonFrame?.midX ?? visible.maxX - size.width / 2 - 8
        let top = min(buttonFrame?.minY ?? visible.maxY, visible.maxY) - 6
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        let frame = NSRect(x: x.rounded(), y: (top - size.height).rounded(), width: size.width, height: size.height)
        if frame != panel.frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
    }

    private static func contentMaxHeight(for screen: NSScreen?) -> CGFloat {
        let visible = screen?.visibleFrame.height ?? 800
        return max(220, visible - 24 - chromeHeight)
    }

    // MARK: Tabs and feature visibility

    private func refreshTabs() {
        guard isOpen else { return }
        model.update(tabs: registry.enabledInOrder, preferred: registry.context.suite.lastTab)
    }

    private func selectionChanged(from old: FeatureID?, to new: FeatureID?) {
        if let new { registry.context.suite.lastTab = new }
        if isOpen { appear(new) }
    }

    /// Moves the "visible" mark to `id`, calling disappear on the old feature and appear on the new one.
    private func appear(_ id: FeatureID?) {
        guard id != appeared else { return }
        if let old = appeared { registry.feature(old).panelDidDisappear() }
        appeared = id
        if let id { registry.feature(id).panelDidAppear() }
    }

    // MARK: Closing on outside clicks, app switches and display changes

    private func installMonitors() {
        removeMonitors()
        // Clicks in other apps, the desktop or other menu bar items.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.close() }
        }) { monitors.append(global) }
        // Clicks in Orbit's own other windows (the status button toggles the panel itself).
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] event in
            guard let self else { return event }
            let window = event.window
            if window === self.panel { self.lastPanelClick = Date() }
            if window !== self.panel && window !== self.anchor?.window { self.close() }
            return event
        }) { monitors.append(local) }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(NSWorkspace.activeSpaceDidChangeNotification, on: workspace) { [weak self] _ in self?.close() }
        // Another app became active: ⌘-Tab, a Dock click, an app opening a window of its own.
        observe(NSWorkspace.didActivateApplicationNotification, on: workspace) { [weak self] note in
            guard let self else { return }
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if MenuBarPanelDismissal.closesOnActivation(of: app?.processIdentifier, ownPID: ProcessInfo.processInfo.processIdentifier,
                                                         lastPanelClick: self.lastPanelClick, now: Date()) {
                self.close()
            }
        }
        // A display was added, removed or rearranged, or changed resolution: the panel's place is stale.
        observe(NSApplication.didChangeScreenParametersNotification, on: .default) { [weak self] _ in self?.close() }
    }

    private func observe(_ name: Notification.Name, on center: NotificationCenter, _ handler: @escaping @MainActor (Notification) -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
            MainActor.assumeIsolated { handler(note) }
        }
        observers.append((center, token))
    }

    private func removeMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers { observer.center.removeObserver(observer.token) }
        observers.removeAll()
        lastPanelClick = nil
    }
}
