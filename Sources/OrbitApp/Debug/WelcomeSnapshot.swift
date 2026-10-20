import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line mode: renders the first-launch welcome panel offscreen to a PNG.
///
///     Orbit --snapshot-welcome <out.png> [--granted] [--dark] [--replace]
///
/// `--granted` draws the "You're all set" state. Refuses to overwrite a PNG unless `--replace`.
enum WelcomeSnapshot {
    static let flag = "--snapshot-welcome"
    static let usage = "usage: Orbit --snapshot-welcome <out.png> [--granted] [--dark] [--replace]"

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
            try render(to: URL(fileURLWithPath: path), granted: rest.contains("--granted"),
                       dark: rest.contains("--dark"), replace: rest.contains("--replace"))
            print("wrote \(path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func render(to output: URL, granted: Bool, dark: Bool, replace: Bool) throws {
        guard output.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if FileManager.default.fileExists(atPath: output.path), !replace {
            throw Failure(description: "\(output.path) exists (pass --replace to overwrite it)")
        }
        let view = WelcomeView(granted: granted, onOpenSettings: {}, onNotNow: {})
            .padding(40)
            .background(LinearGradient(colors: [Color(red: 0.94, green: 0.70, blue: 0.23), Color(red: 1.0, green: 0.42, blue: 0.33),
                                                Color(red: 0.66, green: 0.61, blue: 0.85)],
                                       startPoint: .topTrailing, endPoint: .bottomLeading))
            .environment(\.glassRendering, .flat)
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
