import AppKit
import Combine
import OrbitCore

/// One app in the Windows tab.
struct WindowsAppRow: Identifiable {
    var info: RunningAppInfo
    var icon: NSImage?
    /// The app's listed windows; nil while unknown (Accessibility missing, or not read yet).
    var windows: [WindowsWindowRow]?

    var id: Int32 { info.pid }
}

/// One window under an app in the Windows tab.
struct WindowsWindowRow: Identifiable {
    let id: String
    let title: String
    let isMinimised: Bool
    /// The live window to act on; nil in fixtures.
    let window: AXWindow?
}

/// The Windows tab's state: running apps (NSWorkspace, always) with their windows (Accessibility, when
/// granted), which apps are expanded, and a pending force-quit confirmation. Live, it reads only between
/// `appear()` and `disappear()` (the tab being on screen); a fixture model never touches the system.
@MainActor
final class WindowsPanelModel: ObservableObject {
    struct Live {
        let control: AppControlService
        let settings: WindowsSettings
        let permissions: PermissionCenter
        let closePanel: () -> Void
    }

    @Published private(set) var apps: [WindowsAppRow]
    @Published var expanded: Set<Int32>
    @Published var confirmingForceQuit: Int32?
    @Published private(set) var hasAccessibility: Bool

    private let live: Live?
    private var subscriptions: Set<AnyCancellable> = []
    private var generation = 0
    private var pendingReload: DispatchWorkItem?
    private var isVisible = false

    /// Accessibility reads run here, so a slow app never stalls the panel.
    private static let axQueue = DispatchQueue(label: "com.orbit.windows.accessibility", qos: .userInitiated)

    init(live: Live) {
        self.live = live
        apps = []
        expanded = []
        hasAccessibility = false
    }

    /// A model over fixed rows for snapshots: actions do nothing.
    init(fixtureApps: [WindowsAppRow], expanded: Set<Int32> = [], confirmingForceQuit: Int32? = nil, hasAccessibility: Bool) {
        live = nil
        apps = fixtureApps
        self.expanded = expanded
        self.confirmingForceQuit = confirmingForceQuit
        self.hasAccessibility = hasAccessibility
    }

    // MARK: Visibility

    /// The tab is on screen: read apps (and windows, with Accessibility) and follow changes until `disappear()`.
    func appear() {
        guard let live, !isVisible else { return }
        isVisible = true
        live.permissions.refresh()
        hasAccessibility = live.permissions.status(.accessibility) == .granted
        reload()
        live.control.observe { [weak self] in self?.scheduleReload() }
        live.permissions.$statuses
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                guard let self else { return }
                let granted = statuses[.accessibility] == .granted
                guard granted != self.hasAccessibility else { return }
                self.hasAccessibility = granted
                self.scheduleReload()
            }
            .store(in: &subscriptions)
        live.settings.$showMinimised
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.scheduleReload() }
            .store(in: &subscriptions)
    }

    /// The tab left the screen: stop observing and drop the windows (and their Accessibility elements).
    func disappear() {
        guard let live, isVisible else { return }
        isVisible = false
        live.control.stopObserving()
        subscriptions.removeAll()
        pendingReload?.cancel()
        pendingReload = nil
        generation += 1
        confirmingForceQuit = nil
        apps = []
    }

    private func scheduleReload(after delay: TimeInterval = 0.05) {
        guard isVisible else { return }
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reload() }
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func reload() {
        guard let live, isVisible else { return }
        let infos = RunningAppList.sort(live.control.runningApps())
        // Keep the windows already read while they are read again, so rows don't flicker.
        let previous = Dictionary(apps.map { ($0.id, $0.windows) }, uniquingKeysWith: { first, _ in first })
        apps = infos.map { info in
            WindowsAppRow(info: info, icon: live.control.icon(for: info.pid),
                          windows: hasAccessibility ? (previous[info.pid] ?? nil) : nil)
        }
        expanded.formIntersection(infos.map(\.pid))
        if let pid = confirmingForceQuit, !infos.contains(where: { $0.pid == pid }) { confirmingForceQuit = nil }
        guard hasAccessibility else { return }
        readWindows(of: infos.map(\.pid))
    }

    private func readWindows(of pids: [Int32]) {
        guard let live else { return }
        generation += 1
        let generation = generation
        let showMinimised = live.settings.showMinimised
        let names = Dictionary(apps.map { ($0.id, $0.info.name) }, uniquingKeysWith: { first, _ in first })
        Self.axQueue.async {
            var read: [Int32: [WindowsWindowRow]] = [:]
            for pid in pids {
                let appName = names[pid] ?? ""
                read[pid] = AXWindowService.listedWindows(of: pid, showMinimised: showMinimised).map { window in
                    WindowsWindowRow(id: window.id, title: WindowListing.displayTitle(window.title, appName: appName),
                                     isMinimised: window.isMinimised, window: window)
                }
            }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, self.generation == generation else { return }
                    for index in self.apps.indices {
                        if let windows = read[self.apps[index].id] { self.apps[index].windows = windows }
                    }
                }
            }
        }
    }

    // MARK: App actions (no permission needed)

    func toggleExpanded(_ app: WindowsAppRow) {
        if expanded.contains(app.id) { expanded.remove(app.id) } else { expanded.insert(app.id) }
    }

    func focus(_ app: WindowsAppRow) {
        guard let live else { return }
        live.control.focus(app.id)
        live.closePanel()
    }

    func toggleHidden(_ app: WindowsAppRow) {
        live?.control.setHidden(app.id, !app.info.isHidden)
    }

    func quit(_ app: WindowsAppRow) {
        live?.control.quit(app.id)
    }

    func askToForceQuit(_ app: WindowsAppRow) {
        confirmingForceQuit = app.id
    }

    func cancelForceQuit() {
        confirmingForceQuit = nil
    }

    func confirmForceQuit() {
        guard let pid = confirmingForceQuit else { return }
        confirmingForceQuit = nil
        live?.control.forceQuit(pid)
    }

    // MARK: Window actions (Accessibility)

    func bringForward(_ row: WindowsWindowRow) {
        guard let live, let window = row.window else { return }
        AXWindowService.bringForward(window)
        live.closePanel()
    }

    func toggleMinimised(_ row: WindowsWindowRow) {
        guard let window = row.window else { return }
        AXWindowService.setMinimised(window, !row.isMinimised)
        rereadWindows()
    }

    func close(_ row: WindowsWindowRow) {
        guard let window = row.window else { return }
        AXWindowService.close(window)
        rereadWindows()
    }

    func requestAccessibility() {
        live?.permissions.request(.accessibility)
    }

    /// Minimise and close animate (and a close may ask to save), so read again a moment later.
    private func rereadWindows() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, self.hasAccessibility else { return }
                self.readWindows(of: self.apps.map(\.id))
            }
        }
    }
}
