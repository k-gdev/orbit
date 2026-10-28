import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line modes that draw Clipboard views offscreen over fixture data (no pasteboard, no
/// windows shown, nothing written but the PNG):
///
///     Orbit --snapshot-clipboard-popup <out.png> [--query <text>] [--select <row>] [--dark] [--replace]
///     Orbit --snapshot-clipboard-settings <out.png> [--dark] [--replace]
///
/// The popup is drawn on a desktop-like backdrop, as it appears at the pointer. The settings mode draws
/// the page's whole content at its natural height (the page in the Settings window scrolls, so
/// `--snapshot-settings-page clipboard` only shows its top). Existing PNGs are not replaced without
/// `--replace`; bad arguments exit 64.
enum ClipboardPopupSnapshot {
    static let popupFlag = "--snapshot-clipboard-popup"
    static let settingsFlag = "--snapshot-clipboard-settings"
    static let usage = """
        usage: Orbit --snapshot-clipboard-popup <out.png> [--query <text>] [--select <row>] [--dark] [--replace]
               Orbit --snapshot-clipboard-settings <out.png> [--dark] [--replace]
        """

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        let flag = [popupFlag, settingsFlag].first { arguments.contains($0) }
        guard let flag, let start = arguments.firstIndex(of: flag) else { return }
        let args = Array(arguments[(start + 1)...])
        guard let path = args.first, !path.hasPrefix("--"), path.lowercased().hasSuffix(".png") else { fail64() }
        let url = URL(fileURLWithPath: path)
        let dark = args.contains("--dark")
        if FileManager.default.fileExists(atPath: url.path), !args.contains("--replace") {
            FileHandle.standardError.write(Data("\(url.path) exists (pass --replace to overwrite it)\n".utf8))
            exit(1)
        }
        func value(after option: String) -> String? {
            args.firstIndex(of: option).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        }

        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            let data: Data
            if flag == popupFlag {
                data = try popupPNG(query: value(after: "--query") ?? "", select: value(after: "--select").flatMap(Int.init), dark: dark)
            } else {
                data = try settingsPNG(dark: dark)
            }
            try SnapshotRenderer.write(data, to: url, replace: args.contains("--replace"))
            print("wrote \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func fail64() -> Never {
        FileHandle.standardError.write(Data("\(usage)\n".utf8))
        exit(64)
    }

    @MainActor
    private static func popupPNG(query: String, select: Int?, dark: Bool) throws -> Data {
        let model = ClipboardFixtures.model()
        let state = ClipboardPopupState()
        state.reset(history: model.history)
        state.query = query
        if let select, state.results.indices.contains(select) { state.selectedID = state.results[select].id }
        let popup = ClipboardPopupView(state: state, model: model, verb: "paste", autofocus: false, choose: { _ in }, cancel: {})
        let view = popup
            .padding(.horizontal, 36)
            .padding(.top, 30)
            .padding(.bottom, 44)
            .background(Backdrop(dark: dark))
        return try SnapshotRenderer.png(of: view, size: nil, dark: dark)
    }

    @MainActor
    private static func settingsPNG(dark: Bool) throws -> Data {
        let settings = ClipboardFixtures.settings(ignoredApps: ["com.apple.keychainaccess", "com.apple.Passwords"])
        let model = ClipboardFixtures.model(settings: settings)
        let permissions = PermissionCenter(live: false, fixed: [.accessibility: .notGranted])
        let view = ClipboardSettingsView(settings: settings, model: model, permissions: permissions, conflict: { _ in nil })
            .padding(20)
            .frame(width: 600, alignment: .leading)
            .background(Color(nsColor: .windowBackgroundColor))
        return try SnapshotRenderer.png(of: view, size: nil, dark: dark)
    }
}

/// A soft desktop-like gradient behind the popup.
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
