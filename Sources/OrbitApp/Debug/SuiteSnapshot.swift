import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line modes: render the suite's menu bar panel and Settings pages offscreen with real
/// controls (`SnapshotRenderer`), over fixture data (`SuiteFeature.snapshotViews()`), throwaway defaults
/// suites and a fixture permission state. Nothing touches hardware, the real settings or the menu bar.
///
///     Orbit --snapshot-panel <feature|empty|gallery> <out.png> [--dark] [--replace]
///     Orbit --snapshot-settings-page <page> <out.png> [--dark] [--replace]
///     Orbit --snapshot-suite <dir> [--replace]
///
/// `<feature>` is a `FeatureID` raw value (`sound`, `displays`, …); `empty` draws the panel with every
/// feature off; `gallery` fills it with `PanelGallery` (every shared control in use). `<page>` is `general`, `wheel`, `features`, `about` or a feature. `--snapshot-suite`
/// writes `panel-<id>-{light,dark}.png` (and `panel-empty-…`, `panel-gallery-…`) and `settings-<page>-{light,dark}.png` for
/// everything. Existing PNGs are never replaced without `--replace`; bad arguments exit 64.
enum SuiteSnapshot {
    static let panelFlag = "--snapshot-panel"
    static let pageFlag = "--snapshot-settings-page"
    static let suiteFlag = "--snapshot-suite"
    static let usage = """
        usage: Orbit --snapshot-panel <\((FeatureID.allCases.map(\.rawValue) + ["empty", "gallery"]).joined(separator: "|"))> <out.png> [--dark] [--replace]
               Orbit --snapshot-settings-page <\(SettingsPage.railOrder.map(\.argument).joined(separator: "|"))> <out.png> [--dark] [--replace]
               Orbit --snapshot-suite <dir> [--replace]
        """

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        if let start = arguments.firstIndex(of: panelFlag) {
            let args = Array(arguments[(start + 1)...])
            guard args.count >= 2, !args[1].hasPrefix("--"), let subject = PanelSubject(argument: args[0]) else { fail64() }
            run { try renderPanel(subject, to: URL(fileURLWithPath: args[1]),
                                  dark: args.contains("--dark"), replace: args.contains("--replace")) }
        } else if let start = arguments.firstIndex(of: pageFlag) {
            let args = Array(arguments[(start + 1)...])
            guard args.count >= 2, !args[1].hasPrefix("--"), let page = SettingsPage(argument: args[0]) else { fail64() }
            run { try renderSettings(page, to: URL(fileURLWithPath: args[1]),
                                     dark: args.contains("--dark"), replace: args.contains("--replace")) }
        } else if let start = arguments.firstIndex(of: suiteFlag) {
            let args = Array(arguments[(start + 1)...])
            guard let dir = args.first, !dir.hasPrefix("--") else { fail64() }
            run { try renderSuite(into: URL(fileURLWithPath: dir, isDirectory: true), replace: args.contains("--replace")) }
        }
    }

    private static func fail64() -> Never {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(64)
    }

    @MainActor
    private static func run(_ body: () throws -> Void) -> Never {
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try body()
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    // MARK: Panel

    /// What a panel snapshot shows.
    enum PanelSubject {
        case feature(FeatureID), empty, gallery

        init?(argument: String) {
            switch argument {
            case "empty": self = .empty
            case "gallery": self = .gallery
            default:
                guard let id = FeatureID(rawValue: argument) else { return nil }
                self = .feature(id)
            }
        }
    }

    /// The panel with all eight tabs and the feature selected (no tabs for `.empty`; the Sound tab with
    /// `PanelGallery` for `.gallery`), on a soft gradient backdrop like the mockup's desktop.
    @MainActor
    static func renderPanel(_ subject: PanelSubject, to url: URL, dark: Bool, replace: Bool) throws {
        try preflight(url, replace: replace)
        try SnapshotRenderer.write(try panelPNG(subject, dark: dark), to: url, replace: replace)
        print("wrote \(url.path)")
    }

    @MainActor
    private static func panelPNG(_ subject: PanelSubject, dark: Bool) throws -> Data {
        try withThrowawayDefaults { defaults in
            let model = PanelModel()
            model.contentMaxHeight = 900
            model.pageProvider = { id in
                if case .gallery = subject { return (AnyView(PanelGallery()), false) }
                let type = FeatureRegistry.featureType(for: id)
                return (type.snapshotViews().panel, type.managesOwnScrolling)
            }
            switch subject {
            case .feature(let id): model.update(tabs: FeatureID.allCases, preferred: id)
            case .empty: model.update(tabs: [], preferred: nil)
            case .gallery: model.update(tabs: FeatureID.allCases, preferred: .sound)
            }
            let view = PanelView(model: model, settings: SettingsStore(defaults: defaults), actions: PanelActions())
                .padding(.horizontal, 32)
                .padding(.top, 28)
                .padding(.bottom, 40)
                .background(Backdrop(dark: dark))
            return try SnapshotRenderer.png(of: view, size: nil, dark: dark)
        }
    }

    // MARK: Settings

    /// The whole Settings window content (rail + page) at its default 760 × 560.
    @MainActor
    static func renderSettings(_ page: SettingsPage, to url: URL, dark: Bool, replace: Bool) throws {
        try preflight(url, replace: replace)
        try SnapshotRenderer.write(try settingsPNG(page, dark: dark), to: url, replace: replace)
        print("wrote \(url.path)")
    }

    @MainActor
    private static func settingsPNG(_ page: SettingsPage, dark: Bool) throws -> Data {
        try withThrowawayDefaults { defaults in
            let suite = SuiteSettings(defaults: defaults)
            suite.enabledFeatures.insert(.sound)
            let capabilities = HelperLocator().locate(customFFmpegPath: nil)
            let dependencies = SettingsDependencies(
                settings: SettingsStore(defaults: defaults),
                suite: suite,
                permissions: PermissionCenter(live: false, fixed: [.accessibility: .granted, .screenRecording: .notGranted,
                                                                   .systemAudioRecording: .notGranted]),
                setEnabled: { id, on in suite.setEnabled(id, on) },
                featureSettings: { id in FeatureRegistry.featureType(for: id).snapshotViews().settings },
                capabilities: capabilities,
                rescan: { capabilities },
                showWelcome: {})
            let view = SettingsRootView(navigation: SettingsNavigation(page: page), dependencies: dependencies)
                .background(Color(nsColor: .windowBackgroundColor))
            return try SnapshotRenderer.png(of: view, size: SettingsRootView.defaultSize, dark: dark)
        }
    }

    // MARK: Everything

    @MainActor
    static func renderSuite(into dir: URL, replace: Bool) throws {
        var jobs: [(name: String, render: (Bool) throws -> Data)] = []
        for feature in FeatureID.allCases {
            jobs.append(("panel-\(feature.rawValue)", { try panelPNG(.feature(feature), dark: $0) }))
        }
        jobs.append(("panel-empty", { try panelPNG(.empty, dark: $0) }))
        jobs.append(("panel-gallery", { try panelPNG(.gallery, dark: $0) }))
        for page in SettingsPage.railOrder {
            jobs.append(("settings-\(page.argument)", { try settingsPNG(page, dark: $0) }))
        }
        let outputs = jobs.flatMap { job in ["light", "dark"].map { dir.appending(path: "\(job.name)-\($0).png") } }
        // Check every target first, so a refusal writes nothing.
        for url in outputs { try preflight(url, replace: replace) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for job in jobs {
            for dark in [false, true] {
                let url = dir.appending(path: "\(job.name)-\(dark ? "dark" : "light").png")
                try SnapshotRenderer.write(try job.render(dark), to: url, replace: replace)
                print("wrote \(url.path)")
            }
        }
    }

    // MARK: Helpers

    private static func preflight(_ url: URL, replace: Bool) throws {
        guard url.pathExtension.lowercased() == "png" else { throw SnapshotRenderer.Failure(description: "output must be a .png") }
        if FileManager.default.fileExists(atPath: url.path), !replace {
            throw SnapshotRenderer.Failure(description: "\(url.path) exists (pass --replace to overwrite it)")
        }
    }

    /// A defaults suite that lives only for `body`, so snapshots never read or write the real settings.
    @MainActor
    private static func withThrowawayDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
        let name = "orbit.snapshot.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else { throw SnapshotRenderer.Failure(description: "no defaults suite") }
        defer { defaults.removePersistentDomain(forName: name) }
        return try body(defaults)
    }
}

/// A soft desktop-like gradient behind the panel snapshot.
private struct Backdrop: View {
    let dark: Bool

    var body: some View {
        ZStack {
            LinearGradient(colors: dark ? [Color(red: 0.11, green: 0.09, blue: 0.22), Color(red: 0.05, green: 0.04, blue: 0.10)]
                                        : [Color(red: 0.36, green: 0.27, blue: 0.62), Color(red: 0.16, green: 0.12, blue: 0.30)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(red: 0.96, green: 0.70, blue: 0.56).opacity(dark ? 0.35 : 0.9), .clear],
                           center: UnitPoint(x: 0.12, y: 0.15), startRadius: 0, endRadius: 360)
            RadialGradient(colors: [Color(red: 0.56, green: 0.44, blue: 0.77).opacity(dark ? 0.45 : 0.9), .clear],
                           center: UnitPoint(x: 0.88, y: 0.3), startRadius: 0, endRadius: 340)
        }
    }
}
