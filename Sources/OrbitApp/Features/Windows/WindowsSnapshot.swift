import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line modes for the Windows feature, over fixture data only (no running apps, no
/// Accessibility, no ScreenCaptureKit, throwaway defaults):
///
///     Orbit --snapshot-dock-preview <out.png> [--dark] [--titles-only] [--replace]
///     Orbit --snapshot-windows-panel <granted|no-access|force-quit> <out.png> [--dark] [--replace]
///
/// The first draws the Dock preview strip over a mock desktop and Dock, laid out by the real
/// `DockPreviewLayout` above the hovered icon (`--titles-only`: the cards shown without Screen Recording).
/// The second draws the menu bar panel on the Windows tab in one of its states. Existing PNGs are never
/// replaced without `--replace`; bad arguments exit 64.
enum WindowsSnapshot {
    static let previewFlag = "--snapshot-dock-preview"
    static let panelFlag = "--snapshot-windows-panel"
    static let usage = """
        usage: Orbit --snapshot-dock-preview <out.png> [--dark] [--titles-only] [--replace]
               Orbit --snapshot-windows-panel <\(WindowsFixtures.PanelState.allCases.map(\.rawValue).joined(separator: "|"))> <out.png> [--dark] [--replace]
        """

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        if let start = arguments.firstIndex(of: previewFlag) {
            let args = Array(arguments[(start + 1)...])
            guard let path = args.first, !path.hasPrefix("--") else { fail64() }
            run(path: path, replace: args.contains("--replace")) {
                try SnapshotRenderer.png(of: DockPreviewScene(titlesOnly: args.contains("--titles-only")),
                                         size: DockPreviewScene.size, dark: args.contains("--dark"))
            }
        } else if let start = arguments.firstIndex(of: panelFlag) {
            let args = Array(arguments[(start + 1)...])
            guard args.count >= 2, !args[1].hasPrefix("--"), let state = WindowsFixtures.PanelState(rawValue: args[0]) else { fail64() }
            run(path: args[1], replace: args.contains("--replace")) {
                try panelPNG(state, dark: args.contains("--dark"))
            }
        }
    }

    private static func fail64() -> Never {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(64)
    }

    @MainActor
    private static func run(path: String, replace: Bool, render: () throws -> Data) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let url = URL(fileURLWithPath: path)
        do {
            guard url.pathExtension.lowercased() == "png" else { throw SnapshotRenderer.Failure(description: "output must be a .png") }
            if FileManager.default.fileExists(atPath: url.path), !replace {
                throw SnapshotRenderer.Failure(description: "\(url.path) exists (pass --replace to overwrite it)")
            }
            try SnapshotRenderer.write(try render(), to: url, replace: replace)
            print("wrote \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// The menu bar panel with every tab and Windows selected, like `--snapshot-panel windows`.
    @MainActor
    private static func panelPNG(_ state: WindowsFixtures.PanelState, dark: Bool) throws -> Data {
        let fixture = WindowsFixtures.panelModel(state)
        let model = PanelModel()
        model.contentMaxHeight = 900
        model.pageProvider = { _ in (AnyView(WindowsPanelView(model: fixture)), false) }
        model.update(tabs: FeatureID.allCases, preferred: .windows)
        let view = PanelView(model: model, settings: SettingsStore(defaults: SnapshotFixtures.defaults()), actions: PanelActions())
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .background(MockDesktop(dark: dark))
        return try SnapshotRenderer.png(of: view, size: nil, dark: dark)
    }
}

/// A mock desktop with a Dock along the bottom (auto-hidden Dock shown, as on Kevo's Mac), Safari's icon
/// hovered, and the real strip above it placed by `DockPreviewLayout`.
private struct DockPreviewScene: View {
    let titlesOnly: Bool

    static let size = CGSize(width: 1000, height: 400)
    private static let iconSize: CGFloat = 52
    private static let iconSpacing: CGFloat = 10
    private static let dockPadding: CGFloat = 9
    private static let dockBottom: CGFloat = 6
    private static let dockApps: [(name: String, path: String, running: Bool)] = [
        ("Finder", "/System/Library/CoreServices/Finder.app", true),
        ("Safari", "/Applications/Safari.app", true),
        ("Mail", "/System/Applications/Mail.app", true),
        ("Messages", "/System/Applications/Messages.app", true),
        ("Music", "/System/Applications/Music.app", true),
        ("Notes", "/System/Applications/Notes.app", false),
        ("Calendar", "/System/Applications/Calendar.app", true),
        ("Terminal", "/System/Applications/Utilities/Terminal.app", true),
        ("System Settings", "/System/Applications/System Settings.app", false),
    ]
    private static let hoveredIndex = 1

    @StateObject private var model = DockPreviewModel()
    @Environment(\.colorScheme) private var colorScheme

    private static var dockWidth: CGFloat {
        CGFloat(dockApps.count) * iconSize + CGFloat(dockApps.count - 1) * iconSpacing + 2 * dockPadding
    }

    private static var dockMinX: CGFloat { (size.width - dockWidth) / 2 }

    /// The icon's frame in the scene's AppKit-style space (origin bottom left, y up), as the Dock watcher reports it.
    private static func iconFrame(_ index: Int) -> CGRect {
        CGRect(x: dockMinX + dockPadding + CGFloat(index) * (iconSize + iconSpacing), y: dockBottom + dockPadding,
               width: iconSize, height: iconSize)
    }

    init(titlesOnly: Bool) {
        self.titlesOnly = titlesOnly
        let model = DockPreviewModel()
        let fixture = WindowsFixtures.previewItems(titlesOnly: titlesOnly)
        model.appName = "Safari"
        model.appIcon = WindowsFixtures.icon(atPath: Self.dockApps[Self.hoveredIndex].path)
        model.items = fixture.items
        model.layout = DockPreviewLayout.make(aspectRatios: fixture.aspectRatios, iconFrame: Self.iconFrame(Self.hoveredIndex),
                                              edge: .bottom, visibleFrame: CGRect(origin: .zero, size: Self.size))
        model.hovered = 0
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MockDesktop(dark: colorScheme == .dark)
            dock
            if let layout = model.layout {
                DockPreviewStrip(model: model)
                    .shadow(color: .black.opacity(0.25), radius: 16, y: 6)
                    .offset(x: layout.stripFrame.minX, y: Self.size.height - layout.stripFrame.maxY)
            }
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
    }

    private var dock: some View {
        let height = Self.iconSize + 2 * Self.dockPadding
        return ZStack(alignment: .topLeading) {
            GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous), tintOpacity: 0.06)
                .frame(width: Self.dockWidth, height: height)
            ForEach(Array(Self.dockApps.enumerated()), id: \.offset) { index, app in
                let frame = Self.iconFrame(index)
                VStack(spacing: 3) {
                    AppIconImage(icon: WindowsFixtures.icon(atPath: app.path), size: Self.iconSize)
                        .scaleEffect(index == Self.hoveredIndex ? 1.08 : 1, anchor: .bottom)
                }
                .offset(x: frame.minX - Self.dockMinX, y: Self.dockPadding)
                if app.running {
                    Circle().fill(colorScheme == .dark ? Color.white.opacity(0.8) : Color.black.opacity(0.55))
                        .frame(width: 4, height: 4)
                        .offset(x: frame.midX - Self.dockMinX - 2, y: height - 5)
                }
            }
        }
        .frame(width: Self.dockWidth, height: height, alignment: .topLeading)
        .offset(x: Self.dockMinX, y: Self.size.height - Self.dockBottom - height)
    }
}

/// A soft desktop gradient behind the snapshots (Orbit's own, not the system wallpaper).
private struct MockDesktop: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.10, blue: 0.22), Color(red: 0.05, green: 0.04, blue: 0.10)]
                                        : [Color(red: 0.42, green: 0.33, blue: 0.66), Color(red: 0.18, green: 0.13, blue: 0.33)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.97, green: 0.70, blue: 0.55).opacity(dark ? 0.32 : 0.85), .clear],
                           center: UnitPoint(x: 0.15, y: 0.2), startRadius: 0, endRadius: 380)
            RadialGradient(colors: [Color(red: 0.55, green: 0.44, blue: 0.78).opacity(dark ? 0.42 : 0.85), .clear],
                           center: UnitPoint(x: 0.85, y: 0.35), startRadius: 0, endRadius: 360)
        }
    }
}
