import AppKit
import OrbitCore
import SwiftUI
import UniformTypeIdentifiers

/// Clipboard's own Settings page content (under the shared header with the on/off switch and the
/// Accessibility row): limits, the popup shortcut, pasting, ignored apps and the stored history.
struct ClipboardSettingsView: View {
    @ObservedObject var settings: ClipboardSettings
    @ObservedObject var model: ClipboardModel
    @ObservedObject var permissions: PermissionCenter
    /// A message when `combo` cannot be the shortcut (another Orbit shortcut already uses it).
    let conflict: (KeyCombo) -> String?

    @State private var confirmingClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Popup shortcut", footnote: shortcutNote) {
                HStack {
                    Text("Open the clipboard popup")
                    Spacer(minLength: 12)
                    KeyComboRecorder(combo: $settings.popupShortcut, conflict: conflict(settings.popupShortcut))
                    if settings.popupShortcut != .clipboardDefault {
                        Button("Reset") { settings.popupShortcut = .clipboardDefault }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection("Pasting",
                            footnote: "Without Accessibility, Orbit copies the entry and you press ⌘V yourself.") {
                Toggle("Paste straight into the app you were in", isOn: $settings.pasteDirectly)
                HStack(spacing: 8) {
                    Text("Accessibility").foregroundStyle(.secondary)
                    PermissionBadge(status: permissions.status(.accessibility))
                    Spacer(minLength: 8)
                    if permissions.status(.accessibility) != .granted {
                        Button("Grant Access") { permissions.request(.accessibility) }
                            .controlSize(.small)
                    }
                }
            }

            SettingsSection("History", footnote: "Pinned entries are never removed automatically and don't count toward these limits.") {
                LimitRow(title: "Keep up to", value: $settings.maxItems,
                         presets: [50, 100, 200, 500, 1_000, 2_000]) { "\($0) entries" }
                LimitRow(title: "Keep for", value: $settings.maxAgeDays,
                         presets: [1, 7, 14, 30, 90, 180, 365]) { $0 == 1 ? "1 day" : "\($0) days" }
                LimitRow(title: "Total size", value: $settings.maxMegabytes,
                         presets: [50, 100, 200, 500, 1_000, 2_000]) { Self.megabytes($0) }
                LimitRow(title: "Largest single copy", value: $settings.maxItemMegabytes,
                         presets: [5, 10, 20, 50, 100, 200]) { Self.megabytes($0) }
            }

            SettingsSection("Ignored apps",
                            footnote: "Copies made in these apps are not recorded. Password managers that mark their copies as secret are skipped automatically.") {
                if settings.ignoredBundleIDs.isEmpty {
                    Text("No apps ignored.").foregroundStyle(.secondary)
                }
                ForEach(settings.ignoredBundleIDs, id: \.self) { id in
                    IgnoredAppRow(bundleID: id) { settings.removeIgnored(id) }
                }
                Button("Add App…", action: addApp)
            }

            SettingsSection("Stored history") {
                HStack {
                    Text(storedSummary).foregroundStyle(.secondary)
                    Spacer(minLength: 12)
                    Button("Clear History…") { confirmingClear = true }
                        .disabled(model.history.items.allSatisfy(\.pinned))
                }
            }
        }
        .onAppear {
            model.loadIfNeeded()
            permissions.refresh()
        }
        // A lowered limit takes effect now, not at the next copy.
        .onChange(of: settings.limits) { _, _ in model.enforceLimits() }
        .confirmationDialog("Clear the clipboard history?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) { model.clear(keepPinned: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every entry except the pinned ones is removed from this Mac.")
        }
    }

    private var shortcutNote: String {
        if settings.popupShortcut == .clipboardDefault {
            return "\(KeyCombo.clipboardDefault.display) is Paste and Match Style in many apps. While Clipboard is on, Orbit takes it over; pick another shortcut to keep both."
        }
        return "While Clipboard is on, this shortcut opens the popup in every app."
    }

    private var storedSummary: String {
        let history = model.history
        let size = ByteCountFormatter.string(fromByteCount: Int64(history.totalBytes), countStyle: .file)
        let pinned = history.items.filter(\.pinned).count
        let count = history.count == 1 ? "1 entry" : "\(history.count) entries"
        return pinned > 0 ? "\(count) (\(pinned) pinned) · \(size)" : "\(count) · \(size)"
    }

    private static func megabytes(_ value: Int) -> String {
        value >= 1_000 && value % 1_000 == 0 ? "\(value / 1_000) GB" : "\(value) MB"
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = "Ignore"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier { settings.addIgnored(id) }
        }
    }
}

/// "Keep up to  [200 entries ⌄]": a pop-up of presets that also shows a value outside them.
private struct LimitRow: View {
    let title: String
    @Binding var value: Int
    let presets: [Int]
    let label: (Int) -> String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            Picker(title, selection: $value) {
                ForEach(Array(Set(presets + [value])).sorted(), id: \.self) { Text(label($0)).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
        }
    }
}

/// An ignored app: its icon and name (or the bundle id when it isn't installed) and a remove button.
private struct IgnoredAppRow: View {
    let bundleID: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon = AppLookup.icon(forBundleID: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(AppLookup.name(forBundleID: bundleID) ?? bundleID)
                if AppLookup.name(forBundleID: bundleID) != nil {
                    Text(bundleID).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(.plain)
                .help("Stop ignoring this app")
        }
    }
}
