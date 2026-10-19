import AppKit
import OrbitCore

/// The actions that talk to the system rather than write files: AirDrop and Terminal.
/// `JobCoordinator.perform` runs these before `JobRunner`.
@MainActor
enum SystemActions {
    static let fallbackTerminalID = "com.apple.Terminal"

    /// Opens the AirDrop picker (not the full Share sheet) for the files.
    static func airDrop(_ urls: [URL]) throws {
        guard let service = NSSharingService(named: .sendViaAirDrop), service.canPerform(withItems: urls) else {
            throw OrbitError.unsupported("AirDrop isn't available right now.")
        }
        NSApp.activate()
        service.perform(withItems: urls)
    }

    /// Opens the terminal app at the item's folder (a file's parent). Falls back to
    /// Terminal when the chosen app isn't installed.
    static func openTerminal(at url: URL, bundleID: String) async throws {
        let directory = FileActions.terminalDirectory(for: url)
        let workspace = NSWorkspace.shared
        let appURL = workspace.urlForApplication(withBundleIdentifier: bundleID)
            ?? workspace.urlForApplication(withBundleIdentifier: fallbackTerminalID)
        guard let appURL else { throw OrbitError.unsupported("Couldn't find Terminal.") }
        if bundleID != fallbackTerminalID, workspace.urlForApplication(withBundleIdentifier: bundleID) == nil {
            Log.info("terminal app \(bundleID) not found; using Terminal")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        do {
            _ = try await workspace.open([directory], withApplicationAt: appURL, configuration: configuration)
        } catch {
            Log.error("could not open \(appURL.lastPathComponent) at \(directory.path): \(error.localizedDescription)")
            throw OrbitError.unsupported("Couldn't open \(appURL.deletingPathExtension().lastPathComponent).")
        }
    }
}
