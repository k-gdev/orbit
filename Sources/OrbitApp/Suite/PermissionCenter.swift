import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import OrbitCore

/// Whether a permission is in place. `unknown` means macOS gives no way to tell (for example the
/// audio-capture preflight is missing on this system).
enum PermissionStatus: Sendable {
    case granted, notGranted, unknown
}

/// Status and requests for the suite's privacy permissions. `refresh()` only reads (no prompt);
/// `request(_:)` is the only call that can put a system prompt on screen, and the registry makes it only
/// when the user turns on a feature whose `PermissionUse.requestOnEnable` is true.
///
/// Statuses refresh when Orbit becomes active, when the Settings window becomes key, and once a second
/// for two minutes after a request (macOS sends no notification when the user flips a switch in System
/// Settings).
@MainActor
final class PermissionCenter: ObservableObject {
    @Published private(set) var statuses: [SuitePermission: PermissionStatus] = [:]

    private var observer: NSObjectProtocol?
    private var pollTimer: Timer?
    private var pollDeadline = Date.distantPast
    private let readsLive: Bool
    /// Remembers which permissions Orbit has asked for before (macOS prompts only the first time).
    private let defaults: UserDefaults

    /// `live: false` (snapshots) never touches TCC: every status is `fixed`. `defaults` records which
    /// permissions have been requested before (key `suite.permissionAsked.<permission>`).
    init(live: Bool = true, fixed: [SuitePermission: PermissionStatus] = [:], defaults: UserDefaults = .standard) {
        readsLive = live
        self.defaults = defaults
        guard live else {
            statuses = Dictionary(uniqueKeysWithValues: SuitePermission.allCases.map { ($0, fixed[$0] ?? .notGranted) })
            return
        }
        refresh()
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func status(_ permission: SuitePermission) -> PermissionStatus {
        statuses[permission] ?? .unknown
    }

    /// Whether this macOS has the permission at all (System Audio Recording needs 14.2).
    func isAvailable(_ permission: SuitePermission) -> Bool {
        permission.isAvailableOnThisMac
    }

    /// Re-reads every status. Never prompts.
    func refresh() {
        guard readsLive else { return }
        var next: [SuitePermission: PermissionStatus] = [:]
        for permission in SuitePermission.allCases { next[permission] = Self.read(permission) }
        if next != statuses { statuses = next }
    }

    /// Asks macOS for `permission` (a system prompt the first time; later macOS only lists Orbit in
    /// System Settings, so this also opens the right pane when the prompt can't appear again).
    func request(_ permission: SuitePermission) {
        guard readsLive else { return }
        guard permission.isAvailableOnThisMac else {
            Log.info("not requesting \(permission.rawValue): \(permission.unavailableReason ?? "unavailable")")
            return
        }
        let askedKey = "suite.permissionAsked.\(permission.rawValue)"
        let askedBefore = defaults.bool(forKey: askedKey)
        defaults.set(true, forKey: askedKey)
        Log.info("requesting permission: \(permission.rawValue)\(askedBefore ? " (asked before)" : "")")
        switch permission {
        case .accessibility:
            // Its prompt offers Open System Settings itself, every time access is missing.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            // The first request shows macOS's prompt and returns false while it is up, so the pane opens
            // only when this permission was requested before (macOS won't prompt a second time).
            if !CGRequestScreenCaptureAccess() && askedBefore && Self.read(.screenRecording) != .granted {
                openSettingsLater(permission)
            }
        case .systemAudioRecording:
            // Denied before: macOS won't ask again, so go to the pane. Undetermined: show the prompt.
            if AudioCaptureTCC.preflight() == .notGranted || !AudioCaptureTCC.request(completion: { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }) {
                openSettings(permission)
            }
        }
        pollAfterRequest()
    }

    /// Opens System Settings at this permission's list (nothing when this macOS doesn't have it).
    func openSettings(_ permission: SuitePermission) {
        guard permission.isAvailableOnThisMac else { return }
        NSWorkspace.shared.open(permission.settingsURL)
        pollAfterRequest()
    }

    private func openSettingsLater(_ permission: SuitePermission) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openSettings(permission) }
    }

    /// Re-reads once a second for two minutes, then stops (bounded, so no lasting cost).
    private func pollAfterRequest() {
        pollDeadline = Date().addingTimeInterval(120)
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                let allGranted = self.statuses.values.allSatisfy { $0 == .granted }
                if allGranted || Date() > self.pollDeadline {
                    self.pollTimer?.invalidate()
                    self.pollTimer = nil
                }
            }
        }
    }

    private static func read(_ permission: SuitePermission) -> PermissionStatus {
        switch permission {
        case .accessibility: AXIsProcessTrusted() ? .granted : .notGranted
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .systemAudioRecording: AudioCaptureTCC.preflight()
        }
    }
}

extension SuitePermission {
    /// Whether the running macOS has this permission (and its System Settings pane).
    var isAvailableOnThisMac: Bool { isAvailable(on: ProcessInfo.processInfo.operatingSystemVersion) }

    /// Why the permission can't be granted on this Mac, or nil.
    var unavailableReason: String? {
        guard !isAvailableOnThisMac, let v = minimumSystemVersion else { return nil }
        return "Needs macOS \(v.majorVersion).\(v.minorVersion) or later"
    }
}

/// System Audio Recording ("kTCCServiceAudioCapture") has no public status API, so this reads and
/// requests it through the private TCC framework via `PrivateSymbol`. Process taps need macOS 14.2.
enum AudioCaptureTCC {
    private static let framework = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    // TCC keeps the block and calls it once the prompt is answered, so it must be @escaping: a non-escaping
    // block that outlives the call traps ("non-escaping closure has escaped"), which crashed turning Sound on.
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    /// 0 = granted, 1 = denied; anything else (not yet asked, or a missing symbol) is unknown.
    static func preflight() -> PermissionStatus {
        guard #available(macOS 14.2, *),
              let fn = PrivateSymbol.load("TCCAccessPreflight", from: framework, as: Preflight.self) else { return .unknown }
        switch fn(service, nil) {
        case 0: return .granted
        case 1: return .notGranted
        default: return .unknown
        }
    }

    /// Shows the system prompt. Returns false when the request API is unavailable.
    @discardableResult
    static func request(completion: @escaping (Bool) -> Void) -> Bool {
        guard #available(macOS 14.2, *),
              let fn = PrivateSymbol.load("TCCAccessRequest", from: framework, as: Request.self) else { return false }
        fn(service, nil) { granted in completion(granted) }
        return true
    }
}
