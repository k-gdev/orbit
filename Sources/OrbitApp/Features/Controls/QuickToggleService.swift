import AppKit
import ObjectiveC
import OrbitCore

/// Reads and sets the Quick Toggles' system settings (spec §8.3), each by the least invasive route that
/// needs no permission:
///
/// - Dark Mode: read `AppleInterfaceStyle` in the global domain; set through SkyLight's
///   `SLSSetAppearanceThemeLegacy` (via `PrivateSymbol`), the call System Settings' own switch makes,
///   so no Automation permission for System Events is needed.
/// - Hide Desktop / Hidden Files: `com.apple.finder` `CreateDesktop` / `AppleShowAllFiles` through
///   CFPreferences, then Finder restarts (the UI says so).
/// - Night Shift: CoreBrightness `CBBlueLightClient` through the Objective-C runtime.
///
/// Every read is cheap and done only while the panel is open or right after a change.
@MainActor
final class QuickToggleService {
    private let nightShift = NightShiftClient()

    /// The current value, or nil when the toggle can't be read on this Mac.
    func read(_ id: QuickToggleID) -> PreferenceValue? {
        switch id {
        case .darkMode: .bool(AppearanceSwitch.isDark)
        case .hideDesktopIcons: FinderPreferences.read(FinderPreferences.createDesktop)
        case .showHiddenFiles: FinderPreferences.read(FinderPreferences.showAllFiles)
        case .nightShift: nightShift.isEnabled.map(PreferenceValue.bool)
        case .doNotDisturb, .ejectDrives, .micMute: nil
        }
    }

    /// Why a toggle can't work on this Mac, or nil.
    func unavailableReason(_ id: QuickToggleID) -> String? {
        switch id {
        case .darkMode: AppearanceSwitch.isAvailable ? nil : "Not available"
        case .nightShift: nightShift.isSupported ? nil : "Not available"
        default: nil
        }
    }

    /// Whether the appearance is on Auto (light by day, dark by night).
    var isAutomaticAppearance: Bool { AppearanceSwitch.isAutomatic }

    /// Writes `value` (Finder settings restart Finder). For Dark Mode, `automatic` turns the
    /// appearance's Auto setting off before switching, or back on after restoring (nil: untouched).
    /// Throws when the change didn't take.
    func write(_ id: QuickToggleID, _ value: PreferenceValue, automatic: Bool? = nil) async throws {
        Log.info("quick toggle: \(id.rawValue) → \(value)\(automatic.map { " (Auto \($0 ? "on" : "off"))" } ?? "")")
        switch id {
        case .darkMode:
            let dark = value == .bool(true)
            // Auto off first, as System Settings does when you pick Light or Dark, so the choice sticks.
            if automatic == false { AppearanceSwitch.setAutomatic(false) }
            try AppearanceSwitch.set(dark: dark)
            // The appearance preference follows within a moment; if it doesn't, say so rather than pretend.
            for _ in 0..<10 where AppearanceSwitch.isDark != dark {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard AppearanceSwitch.isDark == dark else {
                throw QuickToggleError(message: "macOS didn’t switch the appearance.")
            }
            // Restoring: Auto back on, which then picks the appearance for the time of day.
            if automatic == true { AppearanceSwitch.setAutomatic(true) }
        case .hideDesktopIcons:
            try FinderPreferences.write(FinderPreferences.createDesktop, value)
            await FinderPreferences.relaunchFinder()
        case .showHiddenFiles:
            try FinderPreferences.write(FinderPreferences.showAllFiles, value)
            await FinderPreferences.relaunchFinder()
        case .nightShift:
            let on = value == .bool(true)
            try nightShift.setEnabled(on)
            for _ in 0..<10 where nightShift.isEnabled != on {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard nightShift.isEnabled == on else { throw QuickToggleError(message: "Night Shift didn’t change.") }
        case .doNotDisturb, .ejectDrives, .micMute:
            break
        }
    }
}

struct QuickToggleError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

// MARK: - Dark Mode

/// The system appearance. Reading needs nothing; switching uses SkyLight's private
/// `SLSSetAppearanceThemeLegacy(bool)` and `SLSSetAppearanceThemeSwitchesAutomatically(bool)` (Auto),
/// loaded with `PrivateSymbol` (missing → unavailable / Auto left alone).
enum AppearanceSwitch {
    private static let skyLight = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
    private typealias SetTheme = @convention(c) (Bool) -> Void
    private typealias GetFlag = @convention(c) () -> Bool

    /// Whether the appearance is on Auto: SkyLight's getter, else the `AppleInterfaceStyleSwitchesAutomatically` preference.
    static var isAutomatic: Bool {
        if let get = PrivateSymbol.load("SLSGetAppearanceThemeSwitchesAutomatically", from: skyLight, as: GetFlag.self) {
            return get()
        }
        let value = CFPreferencesCopyValue("AppleInterfaceStyleSwitchesAutomatically" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return PreferenceValue.parse(value) == .bool(true)
    }

    /// Turns Auto on or off. Without the SkyLight call, Auto is left as it is (logged).
    static func setAutomatic(_ on: Bool) {
        guard let set = PrivateSymbol.load("SLSSetAppearanceThemeSwitchesAutomatically", from: skyLight, as: SetTheme.self) else {
            Log.info("appearance: can't change Auto on this macOS")
            return
        }
        set(on)
    }

    static var isDark: Bool {
        let value = CFPreferencesCopyValue("AppleInterfaceStyle" as CFString, kCFPreferencesAnyApplication,
                                           kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        return (value as? String)?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    static var isAvailable: Bool { PrivateSymbol.exists("SLSSetAppearanceThemeLegacy", in: skyLight) }

    static func set(dark: Bool) throws {
        guard let setTheme = PrivateSymbol.load("SLSSetAppearanceThemeLegacy", from: skyLight, as: SetTheme.self) else {
            throw QuickToggleError(message: "macOS doesn’t offer a way to switch the appearance here.")
        }
        setTheme(dark)
    }
}

// MARK: - Finder

/// Finder's `CreateDesktop` and `AppleShowAllFiles`, written through CFPreferences (the same store
/// `defaults` uses). Finder reads them at launch, so it restarts afterwards.
enum FinderPreferences {
    static let domain = "com.apple.finder" as CFString
    static let createDesktop = "CreateDesktop"
    static let showAllFiles = "AppleShowAllFiles"
    private static let finderID = "com.apple.finder"

    static func read(_ key: String) -> PreferenceValue {
        PreferenceValue.parse(CFPreferencesCopyAppValue(key as CFString, domain))
    }

    /// Writes a boolean, or removes the key for `.absent` (Finder's default), and checks it stuck.
    static func write(_ key: String, _ value: PreferenceValue) throws {
        let raw: CFPropertyList? = switch value {
        case .absent: nil
        case .bool(let flag): flag as CFBoolean
        }
        CFPreferencesSetAppValue(key as CFString, raw, domain)
        guard CFPreferencesAppSynchronize(domain), read(key) == value else {
            throw QuickToggleError(message: "Finder’s settings couldn’t be changed.")
        }
    }

    /// Quits Finder (SIGTERM, as `killall Finder` does) and makes sure it comes back.
    static func relaunchFinder() async {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: finderID) {
            kill(app.processIdentifier, SIGTERM)
            for _ in 0..<30 where !app.isTerminated {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        // macOS normally relaunches Finder by itself; start it if it hasn't come back.
        try? await Task.sleep(for: .milliseconds(1500))
        guard NSRunningApplication.runningApplications(withBundleIdentifier: finderID).isEmpty,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: finderID) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

// MARK: - Night Shift

/// CoreBrightness's `CBBlueLightClient`, reached through the Objective-C runtime after `PrivateSymbol`
/// opens the framework. `getBlueLightStatus:` fills a small struct whose second byte is "enabled" (the
/// Control Center switch); `setEnabled:` flips it. Anything missing reads as unsupported.
@MainActor
final class NightShiftClient {
    private static let framework = "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
    private typealias GetStatus = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> ObjCBool
    private typealias SetEnabled = @convention(c) (AnyObject, Selector, ObjCBool) -> ObjCBool
    private typealias ClassBool = @convention(c) (AnyObject, Selector) -> ObjCBool

    private var client: NSObject?
    private var loaded = false

    private func loadClient() -> NSObject? {
        if loaded { return client }
        loaded = true
        // Opens the framework through the shared wrapper (logs once if it's missing).
        guard PrivateSymbol.exists("OBJC_CLASS_$_CBBlueLightClient", in: Self.framework),
              let type = NSClassFromString("CBBlueLightClient") as? NSObject.Type else { return nil }
        let instance = type.init()
        guard instance.responds(to: NSSelectorFromString("getBlueLightStatus:")),
              instance.responds(to: NSSelectorFromString("setEnabled:")) else { return nil }
        client = instance
        return instance
    }

    var isSupported: Bool {
        guard loadClient() != nil, let type: AnyClass = NSClassFromString("CBBlueLightClient") else { return false }
        let selector = NSSelectorFromString("supportsBlueLightReduction")
        guard let method = class_getClassMethod(type, selector) else { return true }
        return unsafeBitCast(method_getImplementation(method), to: ClassBool.self)(type, selector).boolValue
    }

    /// Whether Night Shift is switched on, or nil when it can't be read.
    var isEnabled: Bool? {
        guard let client = loadClient() else { return nil }
        let selector = NSSelectorFromString("getBlueLightStatus:")
        // The struct is 40 bytes on current systems; a larger zeroed buffer keeps a future, longer one safe.
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 128, alignment: 16)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: 128)
        let get = unsafeBitCast(client.method(for: selector), to: GetStatus.self)
        guard get(client, selector, buffer).boolValue else { return nil }
        return buffer.load(fromByteOffset: 1, as: UInt8.self) != 0
    }

    func setEnabled(_ on: Bool) throws {
        guard let client = loadClient() else { throw QuickToggleError(message: "Night Shift isn’t available on this Mac.") }
        let selector = NSSelectorFromString("setEnabled:")
        let set = unsafeBitCast(client.method(for: selector), to: SetEnabled.self)
        guard set(client, selector, ObjCBool(on)).boolValue else {
            throw QuickToggleError(message: "Night Shift didn’t change.")
        }
    }
}

// MARK: - Shortcuts (Do Not Disturb)

enum ShortcutsRunner {
    /// The user's Shortcut names (`shortcuts list`), or [] when the tool fails or takes too long.
    static func list() async -> [String] {
        guard let result = try? await FocusShortcut.withTimeout(FocusShortcut.timeout, {
            try await ProcessRunner.run(FocusShortcut.executable, ["list"])
        }) else { return [] }
        return FocusShortcut.parseList(result.stdout)
    }

    /// Runs one Shortcut by name; throws when it fails, or `FocusShortcut.TimedOut` (after terminating
    /// `shortcuts`) when it takes longer than `FocusShortcut.timeout`.
    static func run(_ name: String) async throws {
        _ = try await FocusShortcut.withTimeout(FocusShortcut.timeout) {
            try await ProcessRunner.run(FocusShortcut.executable, FocusShortcut.runArguments(name))
        }
    }
}

// MARK: - Volumes (Eject)

enum VolumeLister {
    private static let keys: Set<URLResourceKey> = [.volumeNameKey, .volumeIsInternalKey, .volumeIsRemovableKey, .volumeIsEjectableKey,
                                                    .volumeIsLocalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey]

    /// Mounted volumes Eject may touch (see `EjectableVolumeFilter`), found off the main thread. The
    /// kernel's mount table is read with `MNT_NOWAIT` (cached, never waits on a server) and network
    /// mounts are dropped before any resource value is read, so a stale SMB/NFS share can't stall it.
    /// Missing facts read conservatively.
    static func ejectable() async -> [VolumeInfo] {
        await Task.detached(priority: .utility) {
            let volumes = EjectableVolumeFilter.worthInspecting(mounts()).compactMap { path -> VolumeInfo? in
                let url = URL(fileURLWithPath: path, isDirectory: true)
                guard let v = try? url.resourceValues(forKeys: keys) else { return nil }
                return VolumeInfo(path: path, name: v.volumeName ?? url.lastPathComponent, isInternal: v.volumeIsInternal,
                                  isRemovable: v.volumeIsRemovable ?? false, isEjectable: v.volumeIsEjectable ?? false,
                                  isLocal: v.volumeIsLocal ?? false, isRootFileSystem: v.volumeIsRootFileSystem ?? true,
                                  isBrowsable: v.volumeIsBrowsable ?? false)
            }
            return EjectableVolumeFilter.ejectable(volumes)
        }.value
    }

    /// The mount table (`getmntinfo_r_np` with `MNT_NOWAIT`: the kernel's cached copy, thread-safe,
    /// never waits on a server): each mount point and whether it is local.
    private static func mounts() -> [MountEntry] {
        var table: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&table, MNT_NOWAIT)
        defer { free(table) }
        guard count > 0, let table else { return [] }
        return (0..<Int(count)).map { index in
            var entry = table[index]
            let path = withUnsafeBytes(of: &entry.f_mntonname) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            return MountEntry(path: path, isLocal: entry.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }

    /// Unmounts and ejects each volume off the main thread; returns the names ejected and the names that
    /// failed (in use, busy).
    static func eject(_ volumes: [VolumeInfo]) async -> (ejected: [String], failed: [String]) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var ejected: [String] = [], failed: [String] = []
                for volume in volumes {
                    do {
                        try NSWorkspace.shared.unmountAndEjectDevice(at: URL(fileURLWithPath: volume.path))
                        ejected.append(volume.name)
                    } catch {
                        Log.info("eject \(volume.path) failed: \(error.localizedDescription)")
                        failed.append(volume.name)
                    }
                }
                continuation.resume(returning: (ejected, failed))
            }
        }
    }
}
