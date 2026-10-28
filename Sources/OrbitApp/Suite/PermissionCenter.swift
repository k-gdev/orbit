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

    /// `live: false` (snapshots) never touches TCC: every status is `fixed`.
    init(live: Bool = true, fixed: [SuitePermission: PermissionStatus] = [:]) {
        readsLive = live
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
        Log.info("requesting permission: \(permission.rawValue)")
        switch permission {
        case .accessibility:
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            if !CGRequestScreenCaptureAccess() && Self.read(.screenRecording) != .granted {
                // macOS shows its prompt only once per app; after that, the pane is the only route.
                openSettingsLater(permission)
            }
        case .systemAudioRecording:
            if !AudioCaptureTCC.request(completion: { [weak self] _ in
                DispatchQueue.main.async { self?.refresh() }
            }) {
                openSettings(permission)
            }
        }
        pollAfterRequest()
    }

    /// Opens System Settings at this permission's list.
    func openSettings(_ permission: SuitePermission) {
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

/// System Audio Recording ("kTCCServiceAudioCapture") has no public status API, so this reads and
/// requests it through the private TCC framework via `PrivateSymbol`. Process taps need macOS 14.2.
enum AudioCaptureTCC {
    private static let framework = "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC"
    private static let service = "kTCCServiceAudioCapture" as CFString

    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    /// 0 = granted, 1 = denied; anything else (or a missing symbol) is unknown.
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
