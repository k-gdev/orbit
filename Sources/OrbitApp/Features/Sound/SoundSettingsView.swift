import OrbitCore
import SwiftUI

/// What the Sound settings page needs from the outside world (live in the app, fixtures in snapshots).
struct SoundSettingsEnvironment {
    /// The connected microphones.
    var inputDevices: () -> [SoundDeviceItem]
    /// Running Dock apps, for "Add App".
    var runningApps: () -> [SoundAppIdentity]
    /// Name and icon for a pinned bundle ID.
    var identity: (String) -> SoundAppIdentity
    /// A message when another Orbit shortcut already uses this combo ("Already used by Clipboard").
    var conflict: (KeyCombo) -> String?
}

/// Sound's page in Settings: preferred microphone, the mute shortcut (shared with Controls), remembering
/// per-app settings, and pinned apps.
struct SoundSettingsView: View {
    @ObservedObject var settings: SoundSettings
    @ObservedObject var micSettings: MicMuteSettings
    let environment: SoundSettingsEnvironment

    @State private var inputs: [SoundDeviceItem] = []
    @State private var running: [SoundAppIdentity] = []

    init(settings: SoundSettings, micSettings: MicMuteSettings, environment: SoundSettingsEnvironment) {
        self.settings = settings
        self.micSettings = micSettings
        self.environment = environment
        _inputs = State(initialValue: environment.inputDevices())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Microphone", footnote: "With Keep on, Orbit switches the input back whenever macOS picks another microphone while yours is connected (for example when a call app or a new device takes over).") {
                HStack {
                    Text("Preferred microphone")
                    Spacer()
                    Picker("Preferred microphone", selection: preferredMic) {
                        Text("None").tag("")
                        if let missing = missingPreferredMic {
                            Text("Saved microphone (not connected)").tag(missing)
                        }
                        ForEach(inputs) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
                Toggle("Keep using it when macOS switches to another microphone", isOn: $settings.keepPreferredMic)
                    .disabled(settings.preferredMicUID == nil)
            }

            SettingsSection("Mute Shortcut", footnote: "Mutes and unmutes the microphone from anywhere. A crossed-out microphone shows in the menu bar while it is muted. The same mute as the Mic Mute toggle in Controls.") {
                HStack {
                    Text("Mute microphone")
                    Spacer()
                    KeyComboRecorder(combo: $micSettings.muteShortcut, conflict: environment.conflict(micSettings.muteShortcut))
                }
            }

            SettingsSection("Apps") {
                Toggle("Remember each app's volume, mute and output", isOn: $settings.rememberAppStates)
                Text(settings.rememberAppStates ? "Apps keep their settings when Orbit or the app restarts."
                                                : "Apps go back to 100 % on their usual output when Orbit restarts.")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    Text("Pinned apps")
                    Text("Always listed in the Sound tab, even when they are quiet.").font(.caption).foregroundStyle(.secondary)
                }
                if settings.pinnedBundleIDs.isEmpty {
                    Text("No pinned apps").foregroundStyle(.secondary).font(.callout)
                } else {
                    VStack(spacing: 6) {
                        ForEach(settings.pinnedBundleIDs, id: \.self) { bundleID in
                            pinnedRow(environment.identity(bundleID))
                        }
                    }
                }
                HStack {
                    Menu("Add App") {
                        let candidates = running.filter { !settings.isPinned($0.bundleID) }
                        if candidates.isEmpty {
                            Text("No other apps are running")
                        }
                        ForEach(candidates) { app in
                            Button(app.name) { settings.pin(app.bundleID) }
                        }
                    }
                    .fixedSize()
                    Spacer()
                    Button("Forget All App Settings") { settings.forgetAppStates() }
                        .disabled(settings.appStates.isEmpty)
                        .help("Put every app back to 100 %, unmuted, on the usual output")
                }
            }
        }
        .onAppear {
            inputs = environment.inputDevices()
            running = environment.runningApps()
        }
    }

    private var preferredMic: Binding<String> {
        Binding(get: { settings.preferredMicUID ?? "" },
                set: { settings.preferredMicUID = $0.isEmpty ? nil : $0 })
    }

    /// The preferred mic's UID when it is set but not connected (so the picker can still show it).
    private var missingPreferredMic: String? {
        guard let uid = settings.preferredMicUID, !inputs.contains(where: { $0.uid == uid }) else { return nil }
        return uid
    }

    private func pinnedRow(_ app: SoundAppIdentity) -> some View {
        HStack(spacing: 8) {
            SoundAppIconView(icon: app.icon, size: 20)
            Text(app.name)
            Spacer()
            Button {
                settings.unpin(app.bundleID)
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Unpin \(app.name)")
        }
    }
}
