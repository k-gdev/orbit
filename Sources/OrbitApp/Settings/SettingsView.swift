import AppKit
import OrbitCore
import SwiftUI

/// The settings window's content: one scrolling page of sections (spec §6.9).
struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    let capabilities: Capabilities
    let rescan: () -> Capabilities
    let showWelcome: () -> Void

    var body: some View {
        ScrollView {
            SettingsContent(settings: settings, capabilities: capabilities, rescan: rescan, showWelcome: showWelcome)
        }
    }
}

struct SettingsContent: View {
    @ObservedObject var settings: SettingsStore
    @State var capabilities: Capabilities
    let rescan: () -> Capabilities
    let showWelcome: () -> Void
    @State private var loginOn = LoginItem.isEnabled
    @State private var fullDiskAccess = FullDiskAccess.isGranted()
    @State private var loginError: String?
    @State private var triggerMessage: [WheelKind: String] = [:]
    /// True when drawn by `SettingsSnapshot`, whose `ImageRenderer` can't draw AppKit-backed controls.
    private let renderingForSnapshot: Bool

    init(settings: SettingsStore, capabilities: Capabilities, rescan: @escaping () -> Capabilities,
         showWelcome: @escaping () -> Void = {}, renderingForSnapshot: Bool = false) {
        self.showWelcome = showWelcome
        self.renderingForSnapshot = renderingForSnapshot
        self.settings = settings
        self._capabilities = State(initialValue: capabilities)
        self.rescan = rescan
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            section("Triggers") { triggers }
            section("Output") { output }
            section("Copy & Move") { folders }
            section("Terminal") { terminal }
            section("Helpers") { helpers }
            section("General") { general }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }

    // MARK: Triggers

    @ViewBuilder private var triggers: some View {
        Text("Hold these modifiers while dragging files to open a wheel.")
            .font(.caption).foregroundStyle(.secondary)
        ForEach(WheelKind.allCases, id: \.self) { kind in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(kind.title).frame(width: 64, alignment: .leading)
                    ForEach(settings.bindings.combos(for: kind), id: \.self) { combo in
                        HStack(spacing: 4) {
                            Text(combo.symbols).font(.system(size: 13, weight: .medium))
                            Button { remove(combo, from: kind) } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.plain).foregroundStyle(.secondary)
                                .help("Remove this combo")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.1)))
                    }
                    Spacer(minLength: 0)
                    TriggerRecorder { combo in add(combo, to: kind) }
                }
                if let message = triggerMessage[kind] {
                    Text(message).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    private func add(_ combo: ModifierSet, to kind: WheelKind) {
        if let reason = TriggerValidation.rejection(of: combo, for: kind, in: settings.bindings) {
            triggerMessage[kind] = reason
            return
        }
        triggerMessage[kind] = nil
        var b = settings.bindings
        b.set(b.combos(for: kind) + [combo], for: kind)
        settings.bindings = b
    }

    private func remove(_ combo: ModifierSet, from kind: WheelKind) {
        triggerMessage[kind] = nil
        var b = settings.bindings
        b.set(b.combos(for: kind).filter { $0 != combo }, for: kind)
        settings.bindings = b
    }

    // MARK: Output

    @ViewBuilder private var output: some View {
        Toggle("Reveal results in Finder", isOn: $settings.revealInFinder)
        qualitySlider("JPEG quality", $settings.jpegQuality)
        qualitySlider("HEIC quality", $settings.heicQuality)
        qualitySlider("WebP quality", $settings.webpQuality)
        qualitySlider("AVIF quality", $settings.avifQuality)
        Stepper(value: $settings.pdfDPI, in: 72...600, step: 12) {
            Text("PDF resolution: \(settings.pdfDPI) DPI")
        }
        Divider()
        Text("Fit-to-size presets (MB)").font(.subheadline)
        PresetListEditor(title: "Image", values: $settings.imageFitPresets)
        PresetListEditor(title: "Video", values: $settings.videoFitPresets)
        PresetListEditor(title: "PDF", values: $settings.pdfFitPresets)
    }

    private func qualitySlider(_ title: String, _ value: Binding<Double>) -> some View {
        HStack {
            Text(title).frame(width: 110, alignment: .leading)
            Slider(value: value, in: 0.1...1.0)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .monospacedDigit().frame(width: 44, alignment: .trailing)
        }
    }

    // MARK: Copy & Move

    @ViewBuilder private var folders: some View {
        if settings.favouriteFolders.isEmpty {
            Text("No folders yet.").foregroundStyle(.secondary)
        }
        ForEach(settings.favouriteFolders, id: \.self) { url in
            HStack {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                Text(url.lastPathComponent)
                Text((url.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
                Button { settings.favouriteFolders.removeAll { $0 == url } } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.plain).help("Remove folder")
            }
        }
        Button("Add Folder…", action: addFolder)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !settings.favouriteFolders.contains(url) {
            settings.favouriteFolders.append(url)
        }
    }

    // MARK: Terminal

    private static let terminalIDs = ["com.apple.Terminal", "com.googlecode.iterm2",
                                      "com.mitchellh.ghostty", "dev.warp.Warp-Stable"]

    private var terminalChoices: [(id: String, name: String)] {
        let ws = NSWorkspace.shared
        var choices: [(String, String)] = Self.terminalIDs.compactMap { id in
            guard let url = ws.urlForApplication(withBundleIdentifier: id) else { return nil }
            return (id, FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
        }
        if !choices.contains(where: { $0.0 == settings.terminalBundleID }) {
            choices.append((settings.terminalBundleID, "\(settings.terminalBundleID) (not installed)"))
        }
        return choices
    }

    @ViewBuilder private var terminal: some View {
        Picker("Open Terminal actions in", selection: $settings.terminalBundleID) {
            ForEach(terminalChoices, id: \.id) { Text($0.name).tag($0.id) }
        }
    }

    // MARK: Helpers

    @ViewBuilder private var helpers: some View {
        ForEach(Helper.allCases, id: \.self) { helper in
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: capabilities.has(helper) ? "checkmark.circle.fill" : "xmark.circle")
                    .foregroundStyle(capabilities.has(helper) ? Color.green : Color.secondary)
                Text(helper.displayName).frame(width: 70, alignment: .leading)
                if helper == .ffmpeg, let url = capabilities.ffmpeg {
                    Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                } else if !capabilities.has(helper) {
                    Text(helper.installHint).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Installed").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        HStack {
            TextField("Custom ffmpeg path (optional)", text: Binding(
                get: { settings.customFFmpegPath ?? "" },
                set: { settings.customFFmpegPath = $0.isEmpty ? nil : $0 }))
                .textFieldStyle(.roundedBorder)
                .onSubmit { capabilities = rescan() }
            Button("Rescan") { capabilities = rescan() }
        }
    }

    // MARK: General

    @ViewBuilder private var general: some View {
        Toggle("Launch at login", isOn: Binding(get: { loginOn }, set: setLogin))
        if LoginItem.needsApproval {
            Text("Approve Orbit in System Settings → General → Login Items.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if let loginError {
            Text(loginError).font(.caption).foregroundStyle(.red).textSelection(.enabled)
        }
        Toggle("Haptic feedback", isOn: $settings.hapticsEnabled)
        accentRow
        Divider()
        fullDiskAccessRow
    }

    /// Full Disk Access status, re-read when the page appears and whenever a window becomes key (so it
    /// updates after the user comes back from System Settings).
    private var fullDiskAccessRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Full Disk Access")
                Spacer(minLength: 0)
                if fullDiskAccess {
                    Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green)
                } else {
                    Label("Not granted", systemImage: "xmark.circle").foregroundStyle(.secondary)
                }
                Button("Open Privacy Settings") { NSWorkspace.shared.open(FullDiskAccess.settingsURL) }
            }
            Text(fullDiskAccess ? "Orbit can read your folders without asking."
                                : "Without it, macOS asks separately for Desktop, Documents, Downloads and other folders.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Show welcome again", action: showWelcome)
        }
        .onAppear { fullDiskAccess = FullDiskAccess.isGranted() }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            fullDiskAccess = FullDiskAccess.isGranted()
        }
    }

    /// The accent colour: a colour well, its hex, and a reset. `ImageRenderer` can't draw `ColorPicker`
    /// (it is an AppKit control), so `renderingForSnapshot` swaps in a plain swatch of the same size.
    private var accentRow: some View {
        HStack(spacing: 10) {
            Text("Accent colour")
            Spacer(minLength: 0)
            Group {
                if renderingForSnapshot {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(HexColor.parse(settings.accentHex)?.color ?? .clear)
                        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(Color.primary.opacity(0.25), lineWidth: 1))
                        .frame(width: 38, height: 22)
                } else {
                    ColorPicker("Accent colour", selection: accentBinding, supportsOpacity: false)
                        .labelsHidden()
                }
            }
            Text("#" + settings.accentHex)
                .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
            Button("Reset to default") { settings.accentHex = SettingsStore.defaultAccentHex }
                .disabled(settings.accentHex == SettingsStore.defaultAccentHex)
        }
    }

    private var accentBinding: Binding<Color> {
        Binding(
            get: { HexColor.parse(settings.accentHex)?.color ?? OrbitTheme.accent },
            set: { color in
                guard let rgba = NSColor(color).usingColorSpace(.sRGB).map({
                    RGBA(r: Double($0.redComponent), g: Double($0.greenComponent), b: Double($0.blueComponent), a: 1)
                }) else { return }
                settings.accentHex = HexColor.format(rgba)
            })
    }

    private func setLogin(_ on: Bool) {
        do {
            try LoginItem.set(on)
            loginError = nil
        } catch {
            loginError = "Couldn't \(on ? "enable" : "disable") launch at login: \(error.localizedDescription)"
        }
        loginOn = LoginItem.isEnabled
    }
}

/// An editable list of byte-size presets, shown and entered in MB.
private struct PresetListEditor: View {
    let title: String
    @Binding var values: [Int64]
    @State private var draft = ""

    var body: some View {
        HStack(spacing: 6) {
            Text(title).frame(width: 50, alignment: .leading)
            ForEach(values, id: \.self) { v in
                HStack(spacing: 3) {
                    Text(Self.format(v)).monospacedDigit()
                    Button { values.removeAll { $0 == v } } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(Color.primary.opacity(0.1)))
            }
            Spacer(minLength: 0)
            TextField("MB", text: $draft)
                .textFieldStyle(.roundedBorder).frame(width: 56)
                .onSubmit(commit)
            Button("Add", action: commit).disabled(parsed == nil)
        }
    }

    private var parsed: Int64? {
        guard let mb = Double(draft.trimmingCharacters(in: .whitespaces)), mb > 0, mb < 100_000 else { return nil }
        let bytes = Int64((mb * 1_000_000).rounded())
        return values.contains(bytes) ? nil : bytes
    }

    private func commit() {
        guard let bytes = parsed else { return }
        values = (values + [bytes]).sorted()
        draft = ""
    }

    static func format(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_000_000
        return mb == mb.rounded() ? "\(Int(mb))" : String(format: "%g", mb)
    }
}
