import AppKit
import OrbitCore
import SwiftUI

/// Settings → About: version, licence, where the log lives, and the project page.
struct AboutPage: View {
    static let projectURL = URL(string: "https://github.com/k-gdev/orbit")!

    var body: some View {
        SettingsPageScroll(title: "About") {
            HStack(spacing: 14) {
                appIcon.frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Orbit").font(.system(size: 18, weight: .semibold))
                    Text(Self.versionText).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("One menu bar app for files, sound, displays, windows and more.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            SettingsSection("Licence") {
                Text("Orbit is open source under the MIT License. © 2026 k-gdev.")
                Link("github.com/k-gdev/orbit", destination: Self.projectURL)
            }
            SettingsSection("Log") {
                HStack {
                    Text((Log.fileURL.path as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL]) }
                        .disabled(!FileManager.default.fileExists(atPath: Log.fileURL.path))
                }
                Text("Attach this file when you report a problem.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    /// The bundle's icon; an unbundled development build (no icon) shows the menu bar glyph instead.
    @ViewBuilder private var appIcon: some View {
        if Bundle.main.infoDictionary?["CFBundleIconFile"] != nil, let icon = NSApp.applicationIconImage {
            Image(nsImage: icon).resizable()
        } else {
            Image(nsImage: Self.glyph).resizable().renderingMode(.template).foregroundStyle(OrbitTheme.accent)
                .padding(8)
        }
    }

    private static var glyph: NSImage {
        let image = NSImage(size: NSSize(width: OrbitGlyph.side, height: OrbitGlyph.side))
        if let rep = OrbitGlyph.bitmap(busy: false, scale: 8) { image.addRepresentation(rep) }
        image.isTemplate = true
        return image
    }

    /// "Version 1.1.0 (110)" from the bundle, or a note for an unbundled development build.
    static var versionText: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let short = info["CFBundleShortVersionString"] as? String else { return "Development build" }
        let build = info["CFBundleVersion"] as? String
        return "Version \(short)" + (build.map { " (\($0))" } ?? "")
    }
}
