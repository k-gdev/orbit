import AppKit
import Combine
import IOKit.pwr_mgt
import OrbitCore

/// IOKit power assertions for `KeepAwakeEngine`: `IOPMAssertionCreateWithName` /
/// `IOPMAssertionRelease`. They show in `pmset -g assertions` as "Orbit Keep Awake", and macOS drops
/// them by itself if Orbit's process dies.
final class IOPMAsserter: PowerAsserting {
    private var ids: [PowerAssertionKind: IOPMAssertionID] = [:]

    func acquire(_ kind: PowerAssertionKind, reason: String) -> Bool {
        let type = switch kind {
        case .preventSystemSleep: kIOPMAssertionTypePreventUserIdleSystemSleep
        case .preventDisplaySleep: kIOPMAssertionTypePreventUserIdleDisplaySleep
        }
        var id = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else {
            Log.error("keep awake: \(type) refused (\(result))")
            return false
        }
        ids[kind] = id
        return true
    }

    func release(_ kind: PowerAssertionKind) {
        guard let id = ids.removeValue(forKey: kind) else { return }
        IOPMAssertionRelease(id)
    }
}

/// Keep Awake (spec §8.2) in the running app: owns the `KeepAwakeEngine` and the one thing that ends
/// each kind of session — a single timer for timed sessions (and the 10 s poll of ~/Downloads while
/// downloading), the app-quit notification for "while an app runs", and a wake notification so a Mac
/// that slept past the deadline ends the session as soon as it wakes. Nothing runs while it is off.
@MainActor
final class KeepAwakeController: ObservableObject {
    /// The running session, or nil when off.
    @Published private(set) var session: KeepAwakeSession?

    private let engine: KeepAwakeEngine?
    private let settings: ControlsSettings
    /// Called with true when a session starts and false when it ends (the menu bar indicator).
    var onActiveChange: (Bool) -> Void = { _ in }
    /// Short messages for the user ("Keep Awake ended: Xcode quit").
    var onMessage: (ToastContent) -> Void = { _ in }

    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var downloadWatch = DownloadWatch()

    init(settings: ControlsSettings, asserter: PowerAsserting = IOPMAsserter()) {
        self.settings = settings
        engine = KeepAwakeEngine(asserter: asserter)
    }

    /// A state-only stand-in for snapshots: no engine, no assertion, no timer.
    private init(fixtureSettings: ControlsSettings, session: KeepAwakeSession?) {
        settings = fixtureSettings
        engine = nil
        self.session = session
    }

    static func fixture(settings: ControlsSettings, session: KeepAwakeSession?) -> KeepAwakeController {
        KeepAwakeController(fixtureSettings: settings, session: session)
    }

    var isActive: Bool { session != nil }

    /// The switch: off → starts the last mode when it still makes sense (else indefinitely); on → off.
    func toggle() {
        if isActive { stop() } else { start(KeepAwakeMode.resumable(settings.lastMode, now: Date())) }
    }

    /// Starts (or switches to) `mode`. Returns false when it couldn't start (the app isn't running,
    /// nothing is downloading, macOS refused the assertion), after telling the user why.
    @discardableResult
    func start(_ mode: KeepAwakeMode) -> Bool {
        var appName: String?
        switch mode {
        case .whileAppRunning(let bundleID):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                onMessage(ToastContent(message: "That app isn’t running", detail: "Keep Awake didn’t start.", isError: true))
                return false
            }
            appName = app.localizedName
        case .whileDownloading:
            downloadWatch = DownloadWatch()
            guard downloadWatch.update(active: Self.downloadsActive(), now: Date()) else {
                onMessage(ToastContent(message: "Nothing is downloading", detail: "Keep Awake starts when a download in Downloads is in progress.", isError: true))
                return false
            }
        case .until(let date) where date <= Date():
            return false
        default:
            break
        }
        let wasActive = isActive
        guard let engine else {
            session = KeepAwakeSession(startDate: Date(), mode: mode, keepDisplayAwake: settings.keepDisplayAwake, appName: appName)
            return true
        }
        guard engine.start(mode, keepDisplayAwake: settings.keepDisplayAwake, now: Date(), appName: appName) else {
            stopWatching()
            session = nil
            if wasActive { onActiveChange(false) }
            onMessage(ToastContent(message: "Keep Awake couldn’t start", detail: "macOS refused the request.", isError: true))
            return false
        }
        settings.lastMode = mode
        session = engine.session
        watch(mode)
        if !wasActive { onActiveChange(true) }
        Log.info("keep awake: started \(mode)")
        return true
    }

    /// Ends the session and releases every assertion. Idempotent; the feature's `stop()` and quit call it.
    func stop() {
        stopWatching()
        engine?.stop()
        guard session != nil else { return }
        session = nil
        onActiveChange(false)
        Log.info("keep awake: stopped")
    }

    /// The "keep the display awake too" option, applied to a running session at once.
    func setKeepDisplayAwake(_ on: Bool) {
        settings.keepDisplayAwake = on
        guard isActive else { return }
        if let engine {
            engine.setKeepDisplayAwake(on)
            session = engine.session
        } else {
            session?.keepDisplayAwake = on
        }
    }

    // MARK: Ending

    private func watch(_ mode: KeepAwakeMode) {
        stopWatching()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        })
        switch mode {
        case .duration, .until:
            guard let deadline = engine?.session?.deadline else { return }
            let t = Timer(fire: deadline, interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            t.tolerance = 1
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .whileDownloading:
            let t = Timer(timeInterval: DownloadActivity.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .whileAppRunning:
            observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            })
        case .indefinitely:
            break
        }
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }

    /// Re-evaluates the session (deadline, app, downloads) and ends it when it's over.
    private func check() {
        guard let engine, let session = engine.session else { return }
        let now = Date()
        var appRunning = true
        var downloads = true
        switch session.mode {
        case .whileAppRunning(let bundleID):
            appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
        case .whileDownloading:
            downloads = downloadWatch.update(active: Self.downloadsActive(), now: now)
        default:
            break
        }
        guard engine.evaluate(now: now, appRunning: appRunning, downloadsActive: downloads) else { return }
        stopWatching()
        self.session = nil
        onActiveChange(false)
        let why = switch session.mode {
        case .whileAppRunning: "\(session.appName ?? "The app") quit."
        case .whileDownloading: "Downloads finished."
        default: "Time’s up."
        }
        Log.info("keep awake: ended (\(why))")
        onMessage(ToastContent(message: "Keep Awake ended", detail: why + " Your Mac can sleep again."))
    }

    /// Whether ~/Downloads holds a partial download right now (top level only).
    private static func downloadsActive() -> Bool {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
        return DownloadActivity.isActive(fileNames: names)
    }
}
