import AppKit
import OrbitCore
import SwiftUI

/// Fixture data for the Windows snapshots: made-up apps and windows with the system's own app icons, and
/// fake window art for thumbnails. Nothing here reads running apps, Accessibility, ScreenCaptureKit or the
/// real defaults.
@MainActor
enum WindowsFixtures {
    /// Which state of the Windows tab to draw.
    enum PanelState: String, CaseIterable {
        /// Accessibility granted, Safari expanded with a minimised window.
        case granted
        /// Accessibility missing: no window counts, the expanded app offers the permission.
        case noAccess = "no-access"
        /// A force quit waiting for confirmation.
        case forceQuit = "force-quit"
    }

    /// A throwaway defaults suite in its own temp folder (see `FixtureDefaults`).
    static func defaults() -> UserDefaults { FixtureDefaults.make() }

    // MARK: Apps

    private struct FixtureApp {
        let pid: Int32
        let name: String
        let path: String
        var active = false
        var hidden = false
        var windows: [(String, Bool)] = []
    }

    private static let apps: [FixtureApp] = [
        FixtureApp(pid: 501, name: "Safari", path: "/Applications/Safari.app", active: true,
                   windows: [("Orbit Suite — Pull Request #5 · k-gdev/orbit", false), ("Apple Developer Documentation", false),
                             ("Reading List", true)]),
        FixtureApp(pid: 502, name: "Calendar", path: "/System/Applications/Calendar.app", windows: [("Calendar", false)]),
        FixtureApp(pid: 503, name: "Finder", path: "/System/Library/CoreServices/Finder.app",
                   windows: [("Downloads", false), ("orbit", false)]),
        FixtureApp(pid: 504, name: "Mail", path: "/System/Applications/Mail.app", windows: [("Inbox – iCloud", false)]),
        FixtureApp(pid: 505, name: "Messages", path: "/System/Applications/Messages.app", hidden: true, windows: [("Messages", false)]),
        FixtureApp(pid: 506, name: "Music", path: "/System/Applications/Music.app", windows: [("Music", false)]),
        FixtureApp(pid: 507, name: "Notes", path: "/System/Applications/Notes.app"),
        FixtureApp(pid: 508, name: "Terminal", path: "/System/Applications/Utilities/Terminal.app",
                   windows: [("orbit — swift build — 120×36", false), ("~ — zsh", false)]),
    ]

    /// The app's icon from disk. Symlinks are resolved first (`/Applications/Safari.app` is one on macOS 26),
    /// so the icon doesn't carry an alias badge.
    static func icon(atPath path: String) -> NSImage? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return FileManager.default.fileExists(atPath: resolved) ? NSWorkspace.shared.icon(forFile: resolved) : nil
    }

    static func panelModel(_ state: PanelState) -> WindowsPanelModel {
        let granted = state != .noAccess
        let rows = apps.map { app in
            WindowsAppRow(info: RunningAppInfo(pid: app.pid, bundleID: nil, name: app.name, isRegular: true,
                                               isActive: app.active, isHidden: app.hidden),
                          icon: icon(atPath: app.path),
                          windows: granted ? app.windows.enumerated().map { index, window in
                              WindowsWindowRow(id: "\(app.pid)-\(index)", title: window.0, isMinimised: window.1, window: nil)
                          } : nil)
        }
        let sorted = RunningAppList.sort(rows.map(\.info)).compactMap { info in rows.first { $0.id == info.pid } }
        switch state {
        case .granted: return WindowsPanelModel(fixtureApps: sorted, expanded: [501], hasAccessibility: true)
        case .noAccess: return WindowsPanelModel(fixtureApps: sorted, expanded: [501], hasAccessibility: false)
        case .forceQuit: return WindowsPanelModel(fixtureApps: sorted, confirmingForceQuit: 506, hasAccessibility: true)
        }
    }

    // MARK: Dock preview

    /// Safari's three windows: two thumbnails (the first under the pointer) and a minimised one; with
    /// `titlesOnly`, the cards shown without Screen Recording.
    static func previewItems(titlesOnly: Bool) -> (items: [DockPreviewItem], aspectRatios: [CGFloat]) {
        let windows: [(String, FakeWindowArt.Kind?, CGSize)] = [
            ("Orbit Suite — Pull Request #5 · k-gdev/orbit", .browser, CGSize(width: 1440, height: 900)),
            ("Apple Developer Documentation", .docs, CGSize(width: 1200, height: 900)),
            ("Reading List", nil, CGSize(width: 1280, height: 860)),
        ]
        let items = windows.enumerated().map { index, window in
            DockPreviewItem(id: "\(index)", title: window.0, isMinimised: window.1 == nil,
                            thumbnail: titlesOnly ? nil : window.1.flatMap { thumbnail($0, size: window.2) })
        }
        return (items, windows.map { $0.2.width / $0.2.height })
    }

    /// Fake window art rendered offscreen, about the size ScreenCaptureKit would deliver.
    static func thumbnail(_ kind: FakeWindowArt.Kind, size: CGSize) -> CGImage? {
        let height: CGFloat = 400
        let width = (height * size.width / size.height).rounded()
        let renderer = ImageRenderer(content: FakeWindowArt(kind: kind).frame(width: width, height: height))
        renderer.scale = 1
        return renderer.cgImage
    }
}

/// A made-up window for thumbnails: a title bar with traffic lights and a page (a pull request, a
/// documentation page). Shapes only, so `ImageRenderer` draws it.
struct FakeWindowArt: View {
    enum Kind { case browser, docs }

    let kind: Kind

    var body: some View {
        VStack(spacing: 0) {
            titleBar
            switch kind {
            case .browser: pullRequest
            case .docs: documentation
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var titleBar: some View {
        HStack(spacing: 7) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18), Color(red: 0.16, green: 0.79, blue: 0.25)],
                    id: \.self) { Circle().fill($0).frame(width: 11, height: 11) }
            Spacer(minLength: 30)
            Capsule().fill(Color.black.opacity(0.07)).frame(width: 260, height: 20)
                .overlay(Capsule().fill(Color.black.opacity(0.18)).frame(width: 130, height: 6))
            Spacer(minLength: 30)
            RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.12)).frame(width: 40, height: 10)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
        .background(Color(white: 0.955))
        .overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.08)).frame(height: 1) }
    }

    private func bar(_ width: CGFloat, _ height: CGFloat = 9, _ color: Color = Color.black.opacity(0.14)) -> some View {
        RoundedRectangle(cornerRadius: height / 2).fill(color).frame(width: width, height: height)
    }

    private var pullRequest: some View {
        let accent = Color(red: 0.50, green: 0.39, blue: 0.61)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle().fill(accent.opacity(0.8)).frame(width: 26, height: 26)
                bar(220, 14, Color.black.opacity(0.55))
                Spacer()
                Capsule().fill(Color(red: 0.16, green: 0.65, blue: 0.33)).frame(width: 70, height: 22)
            }
            HStack(spacing: 8) { bar(90, 7); bar(60, 7); bar(110, 7) }
            LinearGradient(colors: [Color(red: 0.96, green: 0.70, blue: 0.56), accent, Color(red: 0.23, green: 0.17, blue: 0.43)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .frame(height: 120)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    VStack(alignment: .leading, spacing: 8) { bar(240, 16, .white.opacity(0.9)); bar(160, 9, .white.opacity(0.7)) }
                        .padding(16)
                }
            ForEach(0..<4, id: \.self) { row in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 4).fill(row == 1 ? accent.opacity(0.35) : Color.black.opacity(0.08))
                        .frame(width: 18, height: 18)
                    bar(CGFloat([360, 300, 420, 250][row]), 8)
                    Spacer()
                    bar(50, 7, Color.black.opacity(0.08))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var documentation: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                bar(90, 9, Color.black.opacity(0.4))
                ForEach(0..<9, id: \.self) { i in bar(CGFloat([110, 80, 120, 95, 70, 105, 85, 115, 60][i]), 7,
                                                       i == 3 ? Color(red: 0.0, green: 0.48, blue: 1).opacity(0.7) : Color.black.opacity(0.13)) }
                Spacer(minLength: 0)
            }
            .padding(18)
            .frame(width: 170, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(Color(white: 0.965))
            VStack(alignment: .leading, spacing: 13) {
                bar(300, 20, Color.black.opacity(0.7))
                bar(380, 9)
                bar(340, 9)
                RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.13, green: 0.13, blue: 0.16))
                    .frame(height: 110)
                    .overlay(alignment: .topLeading) {
                        VStack(alignment: .leading, spacing: 9) {
                            bar(180, 7, Color(red: 0.99, green: 0.37, blue: 0.53).opacity(0.85))
                            bar(240, 7, Color(red: 0.42, green: 0.82, blue: 0.97).opacity(0.85))
                            bar(130, 7, Color.white.opacity(0.5))
                            bar(200, 7, Color(red: 0.99, green: 0.79, blue: 0.40).opacity(0.85))
                        }
                        .padding(16)
                    }
                bar(360, 9)
                bar(300, 9)
                bar(330, 9)
                Spacer(minLength: 0)
            }
            .padding(24)
        }
    }
}

/// Throwaway `UserDefaults` for fixtures: an absolute-path suite inside its own temp folder, so nothing is
/// written to `~/Library/Preferences`; every suite and folder made here is removed when the process exits.
/// (The same idea as the shell's `SnapshotFixtures.defaults()`, kept local so this feature builds on its own.)
enum FixtureDefaults {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var made: [(suite: String, folder: URL)] = []

    static func make() -> UserDefaults {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "orbit-windows-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            preconditionFailure("FixtureDefaults: couldn't create \(folder.path): \(error)")
        }
        let suite = folder.appending(path: "prefs", directoryHint: .notDirectory).path
        guard let defaults = UserDefaults(suiteName: suite) else { preconditionFailure("FixtureDefaults: no suite at \(suite)") }
        lock.lock()
        if made.isEmpty { atexit { FixtureDefaults.removeAll() } }
        made.append((suite, folder))
        lock.unlock()
        return defaults
    }

    static func removeAll() {
        lock.lock()
        let items = made
        made.removeAll()
        lock.unlock()
        for item in items {
            UserDefaults(suiteName: item.suite)?.removePersistentDomain(forName: item.suite)
            try? FileManager.default.removeItem(at: item.folder)
        }
    }
}
