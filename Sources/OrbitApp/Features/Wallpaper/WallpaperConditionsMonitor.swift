import AppKit
import CoreGraphics
import IOKit.ps
import OrbitCore

/// Watches the system-wide conditions that pause wallpapers: screen lock, display and system sleep, battery power
/// and Low Power Mode. Per-window "covered" comes from each `WallpaperWindow`'s occlusion state, observed by the
/// manager. Only runs while at least one wallpaper window is up; `stop()` removes every observer and the power
/// source run loop source.
@MainActor
final class WallpaperConditionsMonitor {
    private(set) var screenLocked = false
    private(set) var screensAsleep = false
    private(set) var systemAsleep = false
    private(set) var onBattery = false
    private(set) var lowPowerMode = false

    /// Called on the main thread whenever one of the values above changes.
    var onChange: () -> Void = {}

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var localObservers: [NSObjectProtocol] = []
    private var powerSource: CFRunLoopSource?
    private var powerSourceContext: Unmanaged<WallpaperConditionsMonitor>?
    private(set) var isRunning = false

    var displaysAsleep: Bool { screensAsleep || systemAsleep }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        screenLocked = Self.readScreenLocked()
        onBattery = Self.readOnBattery()
        lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        screensAsleep = false
        systemAsleep = false

        let workspace = NSWorkspace.shared.notificationCenter
        let watch: [(Notification.Name, (WallpaperConditionsMonitor) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.screensAsleep = true }),
            (NSWorkspace.screensDidWakeNotification, { $0.screensAsleep = false }),
            (NSWorkspace.willSleepNotification, { $0.systemAsleep = true }),
            (NSWorkspace.didWakeNotification, { $0.systemAsleep = false }),
        ]
        for (name, apply) in watch {
            workspaceObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    apply(self)
                    self.onChange()
                }
            })
        }

        let distributed = DistributedNotificationCenter.default()
        for (name, locked) in [("com.apple.screenIsLocked", true), ("com.apple.screenIsUnlocked", false)] {
            distributedObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.screenLocked != locked else { return }
                    self.screenLocked = locked
                    self.onChange()
                }
            })
        }

        // Posted on an arbitrary thread; the main queue delivers it here.
        localObservers.append(NotificationCenter.default.addObserver(forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.isLowPowerModeEnabled
                guard now != self.lowPowerMode else { return }
                self.lowPowerMode = now
                self.onChange()
            }
        })

        installPowerSource()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        for observer in distributedObservers { DistributedNotificationCenter.default().removeObserver(observer) }
        for observer in localObservers { NotificationCenter.default.removeObserver(observer) }
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        localObservers.removeAll()
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        powerSourceContext?.release()
        powerSourceContext = nil
    }

    // MARK: Power source

    /// The callback's context holds a retain on the monitor while the source is installed (released in `stop()`),
    /// so a late callback can never reach a freed monitor.
    private func installPowerSource() {
        let retained = Unmanaged.passRetained(self)
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<WallpaperConditionsMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.powerSourceChanged() }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, retained.toOpaque())?.takeRetainedValue() else {
            retained.release()
            Log.error("wallpaper: no power source notifications; battery pause relies on the state at start")
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
        powerSourceContext = retained
    }

    private func powerSourceChanged() {
        guard isRunning else { return }
        let now = Self.readOnBattery()
        guard now != onBattery else { return }
        onBattery = now
        onChange()
    }

    // MARK: Reads

    /// True when the Mac is drawing from its battery (false on desktops and on AC).
    static func readOnBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }

    /// The login session's lock state (`CGSSessionScreenIsLocked`), for the state at start; later changes come
    /// from the `com.apple.screenIs(Un)Locked` notifications.
    static func readScreenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
