import AppKit
import OrbitCore
import SwiftUI

/// Drives the welcome panel's one piece of live state.
@MainActor
final class WelcomeModel: ObservableObject {
    @Published var granted: Bool
    init(granted: Bool) { self.granted = granted }
}

private struct WelcomeHost: View {
    @ObservedObject var model: WelcomeModel
    let onOpenSettings: () -> Void
    let onNotNow: () -> Void

    var body: some View {
        WelcomeView(granted: model.granted, onOpenSettings: onOpenSettings, onNotNow: onNotNow)
    }
}

/// Shows the Full Disk Access welcome. While it is open it re-checks the grant once a second (macOS
/// gives no notification), shows "You're all set" when it flips, and closes itself a moment later.
/// `hasSeenWelcome` is set by either button, by the grant arriving, or by closing the window.
@MainActor
final class WelcomeWindowController {
    private let settings: SettingsStore
    private let isGranted: () -> Bool
    private let openURL: (URL) -> Void
    private var panel: EditorWindowController?
    private var timer: Timer?
    private var model: WelcomeModel?

    init(settings: SettingsStore,
         isGranted: @escaping () -> Bool = { FullDiskAccess.isGranted() },
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.settings = settings
        self.isGranted = isGranted
        self.openURL = openURL
    }

    /// Whether launch should offer the welcome at all.
    var shouldShowOnLaunch: Bool { !settings.hasSeenWelcome && !isGranted() }

    /// Shows the panel, or re-fronts it if it is already open. Orbit is an accessory app, so
    /// `EditorWindowController.present` activates it for the panel to come to the front.
    func show() {
        if let panel, panel.isVisible {
            NSApp.activate()
            return
        }
        let model = WelcomeModel(granted: isGranted())
        self.model = model
        panel = EditorWindowController.present(width: WelcomeView.width, onClose: { [weak self] in self?.didClose() }) { close, _ in
            WelcomeHost(model: model,
                        onOpenSettings: { [weak self] in
                            self?.settings.hasSeenWelcome = true
                            self?.openURL(FullDiskAccess.settingsURL)
                        },
                        onNotNow: { [weak self] in
                            self?.settings.hasSeenWelcome = true
                            close()
                        })
        }
        if model.granted { finish() } else { startPolling() }
    }

    private func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func poll() {
        guard let model, !model.granted, isGranted() else { return }
        model.granted = true
        finish()
    }

    /// The grant is in place: remember it, stop polling, and close after a short confirmation.
    private func finish() {
        settings.hasSeenWelcome = true
        timer?.invalidate()
        timer = nil
        let closing = panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { closing?.close() }
    }

    private func didClose() {
        timer?.invalidate()
        timer = nil
        settings.hasSeenWelcome = true
        panel = nil
        model = nil
    }
}
