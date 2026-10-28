import AppKit
import OrbitCore

/// Running apps and the app-level actions of the Windows tab, through `NSWorkspace` and
/// `NSRunningApplication`: no permission needed. `observe(_:)` reports launches, quits, activation and
/// hide changes; the Windows tab observes only while it is on screen.
@MainActor
final class AppControlService {
    private var observers: [NSObjectProtocol] = []

    /// Every running app as `RunningAppInfo` (the caller sorts and filters with `RunningAppList`).
    func runningApps() -> [RunningAppInfo] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }.map(Self.info)
    }

    static func info(_ app: NSRunningApplication) -> RunningAppInfo {
        let fallback = app.bundleURL?.deletingPathExtension().lastPathComponent ?? "App \(app.processIdentifier)"
        return RunningAppInfo(pid: app.processIdentifier, bundleID: app.bundleIdentifier,
                              name: app.localizedName ?? fallback, isRegular: app.activationPolicy == .regular,
                              isActive: app.isActive, isHidden: app.isHidden)
    }

    func icon(for pid: pid_t) -> NSImage? {
        NSRunningApplication(processIdentifier: pid)?.icon
    }

    /// Calls `onChange` (on the main actor) whenever an app launches, quits, activates, hides or unhides,
    /// until `stopObserving()`.
    func observe(_ onChange: @escaping @MainActor () -> Void) {
        stopObserving()
        let center = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification,
                                          NSWorkspace.didActivateApplicationNotification, NSWorkspace.didHideApplicationNotification,
                                          NSWorkspace.didUnhideApplicationNotification]
        observers = names.map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }

    func stopObserving() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    // MARK: Actions

    /// Brings the app forward like clicking its Dock icon: unhides it and activates it through Launch
    /// Services (which reopens a window for an app that has none), falling back to plain activation.
    func focus(_ pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        if app.isHidden { app.unhide() }
        guard let url = app.bundleURL else {
            app.activate(options: [.activateAllWindows])
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { app.activate(options: [.activateAllWindows]) }
        }
    }

    func setHidden(_ pid: pid_t, _ hidden: Bool) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else { return }
        _ = hidden ? app.hide() : app.unhide()
    }

    /// Asks the app to quit (it may ask to save first, or refuse).
    func quit(_ pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    /// Kills the app at once; unsaved work is lost. The tab confirms before calling this.
    func forceQuit(_ pid: pid_t) {
        _ = NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }
}
