import AppKit
import OrbitCore
import SwiftUI

/// Settings → Controls: Keep Awake options, the Grab Text and mic mute shortcuts, the Do Not Disturb
/// Shortcut, and which Quick Toggles the panel shows.
struct ControlsSettingsView: View {
    @ObservedObject var model: ControlsModel
    @ObservedObject var micMuteSettings: MicMuteSettings
    @State private var loadedShortcuts = false

    private var settings: ControlsSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Keep Awake",
                            footnote: "Keep Awake asks macOS not to idle-sleep (it shows as “Orbit Keep Awake” in pmset). It ends when the time is up, the app quits or downloads finish, when you turn it off, and when Orbit quits. Closing the lid still sleeps the Mac.") {
                Toggle("Also keep the display awake", isOn: Binding(get: { settings.keepDisplayAwake },
                                                                    set: { model.keepAwake.setKeepDisplayAwake($0) }))
                HStack {
                    Text("Custom duration")
                    Spacer()
                    Text(KeepAwakeFormat.duration(settings.customDuration)).monospacedDigit().foregroundStyle(.secondary)
                    Stepper("Custom duration", value: Binding(get: { settings.customDuration }, set: { settings.customDuration = $0 }),
                            in: ControlsSettings.customDurationRange, step: 5 * 60)
                        .labelsHidden()
                }
            }

            SettingsSection("Shortcuts") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Grab Text")
                        Text("Drag over any part of the screen to copy its text").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyComboRecorder(combo: Binding(get: { settings.grabTextShortcut }, set: { settings.grabTextShortcut = $0 }),
                                     conflict: model.shortcutProblem)
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Mute microphone")
                        Text("Shared with the Sound tab; works with Sound off").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    KeyComboRecorder(combo: $micMuteSettings.muteShortcut)
                }
                Text("A QR code or barcode in the area you grab is copied as its contents instead of its text.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsSection("Do Not Disturb",
                            footnote: "macOS has no way for apps to switch Focus, so the Do Not Disturb button runs a Shortcut. In Shortcuts, make one with the “Set Focus” action (Do Not Disturb, Toggle), then choose it here.") {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Picker("Shortcut", selection: Binding(get: { settings.focusShortcutName ?? "" },
                                                          set: { settings.focusShortcutName = $0.isEmpty ? nil : $0 })) {
                        Text("None").tag("")
                        if let chosen = settings.focusShortcutName, !model.shortcuts.contains(chosen) {
                            Text(chosen).tag(chosen)
                        }
                        ForEach(model.shortcuts, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Open Shortcuts") {
                        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.shortcuts") {
                            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
                        }
                    }
                }
            }

            SettingsSection("Quick Toggles",
                            footnote: "Turning a toggle off puts the setting back exactly as it was before Orbit changed it. Toggles stay as you set them when Orbit quits; none of them needs a permission.") {
                Text("Show in the Controls tab:").font(.caption).foregroundStyle(.secondary)
                ForEach(QuickToggleID.allCases, id: \.self) { id in
                    Toggle(isOn: Binding(get: { settings.visibleToggles.contains(id) },
                                         set: { on in
                                             if on { settings.visibleToggles.append(id) }
                                             else { settings.visibleToggles.removeAll { $0 == id } }
                                         })) {
                        HStack(spacing: 8) {
                            Image(systemName: id.symbol).frame(width: 18).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(id.title)
                                Text(id.summary).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .task {
            guard !loadedShortcuts else { return }
            loadedShortcuts = true
            await model.loadShortcuts()
        }
    }
}
