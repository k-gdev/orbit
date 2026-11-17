import OrbitCore
import SwiftUI

/// The Sound tab (mockup: Sound): output and alerts devices with the master volume, the microphone with
/// its level and the shared mute, then one volume pill per app with its output picker.
struct SoundPanelView: View {
    @ObservedObject var model: SoundPanelModel
    @ObservedObject var settings: SoundSettings
    @ObservedObject var micMute: MicMuteService
    @ObservedObject var micSettings: MicMuteSettings

    init(model: SoundPanelModel) {
        self.model = model
        settings = model.settings
        micMute = model.micMute
        micSettings = model.micMute.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Output & Input")
            outputTile
            microphoneTile
            PanelSectionHeader("Apps", trailing: model.appsStatus == .available
                               ? AnyView(PanelLinkButton(settings.showAllApps ? "Show fewer" : "Show all apps") { model.toggleShowAll() })
                               : nil)
                .padding(.top, 6)
            appsSection
        }
    }

    // MARK: Output

    private var outputTile: some View {
        PanelTile {
            HStack {
                Text("Output").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 8)
                devicePicker(selected: model.defaultOutputUID, devices: model.outputs, fallbackSymbol: "speaker.wave.2",
                             select: model.selectOutput)
            }
            PillSlider(value: Binding(get: { model.outputVolume ?? 100 }, set: { model.setOutputVolume($0) }),
                       scale: .percent, isDimmed: model.outputVolume == nil || model.outputMuted,
                       systemImage: speakerSymbol(model.outputMuted ? 0 : model.outputVolume),
                       valueText: { value in
                           guard model.outputVolume != nil else { return "Fixed" }
                           return model.outputMuted ? "Muted" : "\(Int(value.rounded()))"
                       })
                .disabled(model.outputVolume == nil)
                .help(model.outputVolume == nil ? "This device has no volume control of its own" : "Output volume")
            HStack(spacing: 6) {
                Image(systemName: "bell").font(.system(size: 11, weight: .medium))
                Text("Alerts & system sounds").font(.system(size: 12))
                Spacer(minLength: 8)
                devicePicker(selected: model.systemOutputUID, devices: model.outputs, fallbackSymbol: nil, showIcon: false,
                             select: model.selectSystemOutput)
            }
            .foregroundStyle(.secondary)
            .padding(.top, 1)
        }
    }

    // MARK: Microphone

    private var microphoneTile: some View {
        PanelTile {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Microphone").font(.system(size: 13, weight: .semibold))
                    Text(micCaption).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                devicePicker(selected: model.defaultInputUID, devices: model.inputs, fallbackSymbol: "mic", select: model.selectInput)
            }
            HStack(spacing: 8) {
                PillSlider(value: Binding(get: { model.inputVolume ?? 100 }, set: { model.setInputVolume($0) }),
                           scale: .percent, isDimmed: micMute.isMuted || model.inputVolume == nil,
                           systemImage: "mic.fill",
                           valueText: { model.inputVolume == nil ? "Fixed" : "\(Int($0.rounded()))" })
                    .disabled(model.inputVolume == nil)
                PanelRoundButton(systemImage: micMute.isMuted ? "mic.slash.fill" : "mic.fill", isOn: micMute.isMuted) {
                    micMute.toggle()
                }
                .disabled(!micMute.isAvailable)
                .help(micMute.isMuted ? "Unmute the microphone (\(micSettings.muteShortcut.display))"
                                      : "Mute the microphone (\(micSettings.muteShortcut.display))")
            }
            if let name = micMute.unmutableInputName {
                Label("\(name) ignores mute from the Mac, so Orbit can’t mute it. Use the mute button on the mic.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var micCaption: String {
        let shortcut = micSettings.muteShortcut.display
        if micMute.isMuted && !micMute.isMutedByOrbit { return "Muted outside Orbit" }
        if micMute.isMuted { return "Muted · \(shortcut) to unmute" }
        if micMute.unmutableInputName != nil { return "Mute it on the mic" }
        if !micMute.isAvailable { return model.inputs.isEmpty ? "No microphone" : "This microphone can't be muted" }
        return "On · \(shortcut) to mute"
    }

    // MARK: Apps

    @ViewBuilder private var appsSection: some View {
        switch model.appsStatus {
        case .needsNewerSystem:
            notice(symbol: "exclamationmark.circle", title: "Per-app volume needs macOS 14.2",
                   detail: "Update macOS to change each app's volume and output. Your devices and microphone above work now.")
        case .needsPermission:
            notice(symbol: "waveform.badge.exclamationmark", title: "Allow per-app control",
                   detail: "Orbit needs System Audio Recording to change each app's volume and send it to another output. Your devices and microphone above work without it.",
                   button: ("Allow per-app control", model.requestPermission))
        case .available:
            if model.apps.isEmpty {
                notice(symbol: "speaker.zzz", title: "No apps are playing sound",
                       detail: settings.showAllApps ? "No running app has audio open right now."
                                                    : "Apps show up here while they play, along with apps you pin. Show all apps lists every app with audio.")
            } else {
                VStack(spacing: 6) {
                    ForEach(model.apps) { app in
                        SoundAppRow(app: app, model: model, settings: settings)
                    }
                }
            }
        }
    }

    private func notice(symbol: String, title: String, detail: String, button: (String, () -> Void)? = nil) -> some View {
        PanelTile {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(OrbitTheme.accent).frame(width: 22)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let button {
                        Button(button.0, action: button.1)
                            .controlSize(.small)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: Pieces

    private func devicePicker(selected: String?, devices: [SoundDeviceItem], fallbackSymbol: String?, showIcon: Bool = true,
                              select: @escaping (String) -> Void) -> some View {
        let current = devices.first { $0.uid == selected }
        return PanelMenuButton(title: current?.name ?? "None", systemImage: showIcon ? (current?.symbol ?? fallbackSymbol) : nil, maxWidth: 210) {
            Picker("Device", selection: Binding(get: { selected ?? "" }, set: { if !$0.isEmpty { select($0) } })) {
                ForEach(devices) { device in
                    Label(device.name, systemImage: device.symbol).tag(device.uid)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        }
        .disabled(devices.isEmpty)
    }

    private func speakerSymbol(_ volume: Double?) -> String {
        guard let volume else { return "speaker.wave.2.fill" }
        switch volume {
        case ..<1: return "speaker.slash.fill"
        case ..<34: return "speaker.wave.1.fill"
        case ..<67: return "speaker.wave.2.fill"
        default: return "speaker.wave.3.fill"
        }
    }
}

/// One app: a 0–150 % pill (icon = mute, name with level bars or a pin) and a round output picker.
struct SoundAppRow: View {
    let app: SoundAppItem
    @ObservedObject var model: SoundPanelModel
    @ObservedObject var settings: SoundSettings

    var body: some View {
        let preference = settings.preference(for: app.bundleID)
        let pinned = settings.isPinned(app.bundleID)
        let routed = preference.outputUID.flatMap { model.output(uid: $0) }
        let routeMissing = preference.outputUID != nil && routed == nil
        let followed = model.output(uid: app.followedOutputUID ?? model.defaultOutputUID)
        HStack(spacing: 8) {
            PillSlider(value: Binding(get: { settings.preference(for: app.bundleID).volume },
                                      set: { model.setVolume($0, for: app.bundleID) }),
                       scale: PillScale(maximum: AppAudioPreference.volumeRange.upperBound), height: 34, isDimmed: preference.muted,
                       leading: AnyView(SoundAppIconView(icon: app.identity.icon, size: 22).opacity(preference.muted ? 0.5 : 1)),
                       label: AnyView(label(muted: preference.muted, pinned: pinned)),
                       valueText: { preference.muted ? "Muted" : "\(Int($0.rounded()))%" },
                       onLeadingTap: { model.toggleMute(app.bundleID) },
                       onEditingEnded: { model.finishVolumeChange() })
                .help(app.tapFailed
                      ? "Orbit couldn't take over \(app.name)'s audio, so this volume and output aren't applied (it plays as usual). See Orbit's log for why."
                      : (preference.muted ? "Click the icon to unmute \(app.name)" : "Click the icon to mute \(app.name)"))
            PanelRoundMenu(systemImage: routed?.symbol ?? (routeMissing ? "exclamationmark.triangle" : followed?.symbol ?? "hifispeaker"),
                           isHighlighted: preference.outputUID != nil, size: 34) {
                Text("Play \(app.name) on")
                Picker("Output", selection: Binding(get: { preference.outputUID ?? "" },
                                                    set: { model.setOutput($0.isEmpty ? nil : $0, for: app.bundleID) })) {
                    Text(followed.map { "Same as Output (\($0.name))" } ?? "Same as Output").tag("")
                    Divider()
                    ForEach(model.outputs) { device in
                        Label(device.name, systemImage: device.symbol).tag(device.uid)
                    }
                    if routeMissing, let uid = preference.outputUID {
                        Text("Disconnected device").tag(uid)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            .help(routed.map { "\(app.name) plays on \($0.name)" }
                  ?? (routeMissing ? "\(app.name)'s device is not connected; it plays on the output meanwhile" : "\(app.name) plays on the output"))
        }
        .contextMenu {
            Button(pinned ? "Unpin \(app.name)" : "Pin \(app.name)") { model.togglePin(app.bundleID) }
            Button("Reset to 100 %, Same as Output") { model.reset(app.bundleID) }
                .disabled(preference.isDefault)
        }
    }

    private func label(muted: Bool, pinned: Bool) -> some View {
        HStack(spacing: 6) {
            Text(app.name)
            if app.tapFailed {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange)
            }
            if app.isPlaying {
                LevelBars(active: !muted)
            } else if pinned {
                Image(systemName: "pin.fill").font(.system(size: 8.5, weight: .semibold)).foregroundStyle(.secondary)
            }
        }
    }
}

/// An app icon at a given size: the real icon, or a symbol on a rounded coloured tile.
struct SoundAppIconView: View {
    let icon: SoundAppIcon
    let size: CGFloat

    var body: some View {
        switch icon {
        case .image(let image):
            Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
        case .symbol(let name, let tint):
            Image(systemName: name)
                .font(.system(size: size * 0.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(tint))
        }
    }
}
