import AppKit
import ApplicationServices
import OrbitCore

/// A running app's Dock icon under the pointer.
struct DockHover: Equatable {
    let pid: pid_t
    let name: String
    /// The icon's frame in AppKit screen coordinates (y up).
    let iconFrame: CGRect
}

/// Reports which running app's Dock icon the pointer is over, through an `AXObserver` on the Dock's icon
/// list (`kAXSelectedChildrenChangedNotification` on its `AXList`): the Dock "selects" the icon under the
/// pointer. It costs nothing between `stop()` and `start()`, and does nothing without Accessibility. If the
/// Dock restarts, it attaches to the new Dock.
@MainActor
final class DockWatcher {
    nonisolated static let dockBundleID = "com.apple.dock"

    /// Called with the hovered app, or nil when the pointer leaves the Dock or rests on something that is
    /// not a running app (a folder, the Trash, a separator, an app that isn't open).
    var onHover: (DockHover?) -> Void = { _ in }

    private(set) var isRunning = false
    private var observer: AXObserver?
    private var list: AXUIElement?
    /// The Dock process the observer is attached to.
    private var attachedPID: pid_t?
    /// Watches the process list (KVO covers background processes like the Dock, which the launch
    /// notifications may not), to re-attach when the Dock restarts.
    private var processWatch: NSKeyValueObservation?
    private var retry: DispatchWorkItem?
    private var attempts = 0

    func start() {
        guard !isRunning else { return }
        isRunning = true
        attempts = 0
        attach()
        processWatch = NSWorkspace.shared.observe(\.runningApplications, options: []) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.dockMayHaveRestarted() }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        retry?.cancel()
        retry = nil
        processWatch?.invalidate()
        processWatch = nil
        detach()
    }

    /// The process list changed: if the Dock now has another pid (or none was attached), attach to it.
    private func dockMayHaveRestarted() {
        guard isRunning else { return }
        let pid = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first?.processIdentifier
        guard pid != attachedPID else { return }
        detach()
        guard pid != nil else { return }
        attempts = 0
        scheduleAttach(after: 1)
    }

    // MARK: Attaching

    private func attach() {
        detach()
        guard isRunning, AXIsProcessTrusted(),
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleID).first else { return }
        // Every element read here (the Dock, its list, each hovered item) carries `AX.timeout`.
        let app = AX.application(dock.processIdentifier)
        guard let list = AX.elements(app, kAXChildrenAttribute).first(where: { (AX.value($0, kAXRoleAttribute) as String?) == kAXListRole }) else {
            // A Dock that has just launched may not have built its list yet.
            scheduleAttach(after: 1)
            return
        }
        var created: AXObserver?
        guard AXObserverCreate(dock.processIdentifier, Self.callback, &created) == .success, let created else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        guard AXObserverAddNotification(created, list, kAXSelectedChildrenChangedNotification as CFString, refcon) == .success else {
            scheduleAttach(after: 2)
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .commonModes)
        observer = created
        self.list = list
        attachedPID = dock.processIdentifier
        Log.info("windows: watching the Dock (pid \(dock.processIdentifier))")
    }

    private func detach() {
        if let observer {
            if let list { AXObserverRemoveNotification(observer, list, kAXSelectedChildrenChangedNotification as CFString) }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        observer = nil
        list = nil
        attachedPID = nil
    }

    /// Retries a few times (the Dock relaunching), then gives up until the next Dock launch or `start()`.
    private func scheduleAttach(after delay: TimeInterval) {
        retry?.cancel()
        guard isRunning, attempts < 5 else { return }
        attempts += 1
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.attach() }
        }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Runs on the main run loop (the observer's source is added there).
    private static let callback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let watcher = Unmanaged<DockWatcher>.fromOpaque(refcon).takeUnretainedValue()
        MainActor.assumeIsolated { watcher.selectionChanged() }
    }

    // MARK: Reading the hovered icon

    private func selectionChanged() {
        guard isRunning, let list else { return }
        onHover(AX.elements(list, kAXSelectedChildrenAttribute).first.flatMap(hover(for:)))
    }

    private func hover(for item: AXUIElement) -> DockHover? {
        guard (AX.value(item, kAXSubroleAttribute) as String?) == "AXApplicationDockItem",
              let origin = AX.point(item, kAXPositionAttribute), let size = AX.size(item, kAXSizeAttribute) else { return nil }
        let url: URL? = (AX.value(item, kAXURLAttribute) as NSURL?).map { $0 as URL }
        let title: String? = AX.value(item, kAXTitleAttribute)
        guard let app = Self.runningApp(url: url, title: title) else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return DockHover(pid: app.processIdentifier, name: app.localizedName ?? title ?? "",
                         iconFrame: ScreenSpace.flip(CGRect(origin: origin, size: size), primaryHeight: primaryHeight))
    }

    /// The running app behind a Dock item: by bundle location, else by name among regular apps.
    private static func runningApp(url: URL?, title: String?) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        if let url {
            let path = normalised(url)
            if let match = apps.first(where: { $0.bundleURL.map(normalised) == path }) { return match }
        }
        guard let title, !title.isEmpty else { return nil }
        return apps.first { $0.activationPolicy == .regular && $0.localizedName == title }
    }

    private static func normalised(_ url: URL) -> String {
        var path = url.standardizedFileURL.resolvingSymlinksInPath().path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
