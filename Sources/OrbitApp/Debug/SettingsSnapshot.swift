import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line mode (ruling R22): renders the settings page offscreen to a PNG.
///
///     Orbit --snapshot-settings <out.png> [--dark] [--replace]
enum SettingsSnapshot {
    static let flag = "--snapshot-settings"
    static let usage = "usage: Orbit --snapshot-settings <out.png> [--dark] [--replace]"

    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        let rest = Array(arguments[(start + 1)...])
        guard let path = rest.first, !path.hasPrefix("--") else {
            FileHandle.standardError.write(Data("missing output path\n\(usage)\n".utf8))
            exit(64)
        }
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try render(to: URL(fileURLWithPath: path), dark: rest.contains("--dark"), replace: rest.contains("--replace"))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func render(to output: URL, dark: Bool, replace: Bool) throws {
        let fm = FileManager.default
        guard output.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if fm.fileExists(atPath: output.path), !replace {
            throw Failure(description: "\(output.path) exists (pass --replace to overwrite it)")
        }
        // Throwaway defaults suite so the snapshot never reads or writes the real settings.
        let suite = "orbit.snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(description: "no defaults suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        let capabilities = HelperLocator().locate(customFFmpegPath: nil)
        let view = SettingsContent(settings: settings, capabilities: capabilities, rescan: { capabilities }, renderingForSnapshot: true)
            .frame(width: 560)
            .background(Color(nsColor: dark ? .black : .white))
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "rendering failed")
        }
        try png.write(to: output, options: replace ? .atomic : .withoutOverwriting)
    }
}
