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
/// each kind of session — a single timer for timed sessions (re-armed for the deadline if it fires
/// early), the 10 s poll of ~/Downloads while downloading (read off the main thread), the app-quit
/// notification for "while an app runs", and wake / clock-change notifications so a Mac that slept
/// past the deadline, or whose clock moved, re-checks at once. Nothing runs while it is off.
@MainActor
final class KeepAwakeController: ObservableObject {
    /// The running session, or nil when off.
    @Published private(set) var session: KeepAwakeSession?
    /// Whether the display assertion is really held (macOS can refuse it while granting the system one).
    @Published private(set) var displayHeld = false

    private let engine: KeepAwakeEngine?
    private let settings: ControlsSettings
    /// Called with true when a session starts and false when it ends (the menu bar indicator).
    var onActiveChange: (Bool) -> Void = { _ in }
    /// Short messages for the user ("Keep Awake ended: Xcode quit").
    var onMessage: (ToastContent) -> Void = { _ in }

    private var timer: Timer?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var downloadWatch = DownloadWatch()
    /// The Downloads read before a "while downloading" session starts, and the one in flight while it runs.
    private var pendingStart: Task<Void, Never>?
    private var poll: Task<Void, Never>?

    init(settings: ControlsSettings, asserter: PowerAsserting = IOPMAsserter()) {
        self.settings = settings
        engine = KeepAwakeEngine(asserter: asserter)
    }

    /// A state-only stand-in for snapshots: no engine, no assertion, no timer.
    private init(fixtureSettings: ControlsSettings, session: KeepAwakeSession?) {
        settings = fixtureSettings
        engine = nil
        self.session = session
        displayHeld = session?.keepDisplayAwake ?? false
    }

    static func fixture(settings: ControlsSettings, session: KeepAwakeSession?) -> KeepAwakeController {
        KeepAwakeController(fixtureSettings: settings, session: session)
    }

    var isActive: Bool { session != nil }

    /// The switch: off → starts the last mode when it still makes sense (else indefinitely); on → off.
    func toggle() {
        if isActive { stop() } else { start(KeepAwakeMode.resumable(settings.lastMode, now: Date())) }
    }

    /// Starts (or switches to) `mode`. Returns false when it couldn't start (the app isn't running, the
    /// time has passed, macOS refused the assertion), after telling the user why. "While downloading"
    /// first lists ~/Downloads off the main thread and starts (or explains why not) when that returns.
    @discardableResult
    func start(_ mode: KeepAwakeMode) -> Bool {
        pendingStart?.cancel()
        pendingStart = nil
        switch mode {
        case .whileAppRunning(let bundleID):
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
                onMessage(ToastContent(message: "That app isn’t running", detail: "Keep Awake didn’t start.", isError: true))
                return false
            }
            return begin(mode, appName: app.localizedName)
        case .whileDownloading where engine != nil:
            pendingStart = Task { [weak self] in
                let active = await Self.downloadsActive()
                guard let self, !Task.isCancelled else { return }
                self.pendingStart = nil
                guard active else {
                    self.onMessage(ToastContent(message: "Nothing is downloading",
                                                detail: "Keep Awake starts when a download in Downloads is in progress.", isError: true))
                    return
                }
                self.downloadWatch = DownloadWatch()
                _ = self.downloadWatch.update(active: true, now: Date())
                self.begin(.whileDownloading, appName: nil)
            }
            return true
        case .until(let date) where date <= Date():
            return false
        default:
            return begin(mode, appName: nil)
        }
    }

    @discardableResult
    private func begin(_ mode: KeepAwakeMode, appName: String?) -> Bool {
        let wasActive = isActive
        guard let engine else {
            session = KeepAwakeSession(startDate: Date(), mode: mode, keepDisplayAwake: settings.keepDisplayAwake, appName: appName)
            displayHeld = settings.keepDisplayAwake
            return true
        }
        guard engine.start(mode, keepDisplayAwake: settings.keepDisplayAwake, now: Date(), appName: appName) else {
            stopWatching()
            session = nil
            displayHeld = false
            if wasActive { onActiveChange(false) }
            onMessage(ToastContent(message: "Keep Awake couldn’t start", detail: "macOS refused the request.", isError: true))
            return false
        }
        settings.lastMode = mode
        session = engine.session
        displayHeld = engine.holdsDisplayAssertion
        watch(mode)
        if !wasActive { onActiveChange(true) }
        Log.info("keep awake: started \(mode)\(settings.keepDisplayAwake && !displayHeld ? " (display assertion refused)" : "")")
        return true
    }

    /// Ends the session and releases every assertion. Idempotent; the feature's `stop()` and quit call it.
    func stop() {
        pendingStart?.cancel()
        pendingStart = nil
        stopWatching()
        engine?.stop()
        displayHeld = false
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
            displayHeld = engine.holdsDisplayAssertion
        } else {
            session?.keepDisplayAwake = on
            displayHeld = on
        }
    }

    // MARK: Ending

    private func watch(_ mode: KeepAwakeMode) {
        stopWatching()
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }))
        let local = NotificationCenter.default
        observers.append((local, local.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }))
        switch mode {
        case .duration, .until:
            if let deadline = engine?.session?.deadline { arm(at: deadline) }
        case .whileDownloading:
            let t = Timer(timeInterval: DownloadActivity.pollInterval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
            t.tolerance = 2
            RunLoop.main.add(t, forMode: .common)
            timer = t
        case .whileAppRunning:
            observers.append((workspace, workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                                               queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }))
        case .indefinitely:
            break
        }
    }

    /// The single timer of a timed session, (re)scheduled for `date`.
    private func arm(at date: Date) {
        timer?.invalidate()
        let t = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopWatching() {
        timer?.invalidate()
        timer = nil
        poll?.cancel()
        poll = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    /// Re-evaluates the session (deadline, app, downloads) and ends it when it's over. A timed session
    /// that isn't due yet (the timer fired early because the clock moved) gets its timer re-armed.
    private func check() {
        guard let engine, let session = engine.session else { return }
        switch session.mode {
        case .whileDownloading:
            guard poll == nil else { return }
            poll = Task { [weak self] in
                let active = await Self.downloadsActive()
                guard let self, !Task.isCancelled else { return }
                self.poll = nil
                // Ignore a result that arrives after the session changed.
                guard self.engine?.session?.startDate == session.startDate else { return }
                let downloads = self.downloadWatch.update(active: active, now: Date())
                self.conclude(session, appRunning: true, downloads: downloads)
            }
        case .whileAppRunning(let bundleID):
            conclude(session, appRunning: !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty,
                     downloads: true)
        default:
            conclude(session, appRunning: true, downloads: true)
        }
    }

    private func conclude(_ session: KeepAwakeSession, appRunning: Bool, downloads: Bool) {
        guard let engine else { return }
        let now = Date()
        guard engine.evaluate(now: now, appRunning: appRunning, downloadsActive: downloads) else {
            if let next = session.nextCheck(now: now) { arm(at: next) }
            return
        }
        stopWatching()
        self.session = nil
        displayHeld = false
        onActiveChange(false)
        let why = switch session.mode {
        case .whileAppRunning: "\(session.appName ?? "The app") quit."
        case .whileDownloading: "Downloads finished."
        default: "Time’s up."
        }
        Log.info("keep awake: ended (\(why))")
        onMessage(ToastContent(message: "Keep Awake ended", detail: why + " Your Mac can sleep again."))
    }

    /// Whether ~/Downloads holds a partial download right now (top level only), listed off the main
    /// thread so a slow disk can't stall the UI.
    private static func downloadsActive() async -> Bool {
        await Task.detached(priority: .utility) {
            guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
                  let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return false }
            return DownloadActivity.isActive(fileNames: names)
        }.value
    }
}
