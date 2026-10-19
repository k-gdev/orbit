import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line mode (ruling R22a): renders the progress panel or a toast offscreen.
///
///     Orbit --snapshot-hud <progress|toast|error> <out.png> [--replace]
///
/// Uses sample data and a flat glass stand-in; refuses to overwrite a PNG unless `--replace`.
enum HUDSnapshot {
    static let flag = "--snapshot-hud"
    static let usage = "usage: Orbit --snapshot-hud <progress|toast|error> <out.png> [--replace]"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        let args = Array(arguments[(start + 1)...])
        guard args.count >= 2, ["progress", "toast", "error"].contains(args[0]) else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)
        }
        let output = URL(fileURLWithPath: args[1])
        let replace = args.dropFirst(2).contains("--replace")
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try render(kind: args[0], to: output, replace: replace)
            print("wrote \(output.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func render(kind: String, to output: URL, replace: Bool) throws {
        guard output.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if FileManager.default.fileExists(atPath: output.path), !replace {
            throw Failure(description: "\(output.path) exists (pass --replace to overwrite it)")
        }
        let hud: AnyView
        switch kind {
        case "progress":
            hud = AnyView(ProgressPanelView(title: "Converting to MP4", fileName: "geese.mov", countText: "2 of 5",
                                            fraction: 0.4, onCancel: {}))
        case "toast":
            hud = AnyView(ToastView(content: ToastContent(message: "2.4 MB → 610 KB · 75% smaller",
                                                          detail: "Saved to Downloads/Orbit",
                                                          canOpen: true, canReveal: true, canUndo: true),
                                    actions: ToastActions()))
        default:
            hud = AnyView(ToastView(content: ToastContent(message: "Orbit can't do that with this file.", isError: true),
                                    actions: ToastActions()))
        }
        let view = hud
            .padding(40)
            .background(LinearGradient(colors: [Color(red: 0.94, green: 0.70, blue: 0.23), Color(red: 1.0, green: 0.42, blue: 0.33),
                                                Color(red: 0.66, green: 0.61, blue: 0.85)],
                                       startPoint: .topTrailing, endPoint: .bottomLeading))
            .environment(\.glassRendering, .flat)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw Failure(description: "rendering failed")
        }
        try png.write(to: output, options: replace ? .atomic : .withoutOverwriting)
    }
}
