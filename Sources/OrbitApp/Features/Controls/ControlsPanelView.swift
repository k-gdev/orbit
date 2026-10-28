import OrbitCore
import SwiftUI

/// The Controls tab (spec §8.1): Keep Awake on top, the Quick Toggles grid below, then Grab Text.
struct ControlsPanelView: View {
    @ObservedObject var model: ControlsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Sleep")
            KeepAwakeTile(model: model)

            if !model.settings.visibleToggles.isEmpty {
                PanelSectionHeader("Quick Toggles", trailing: AnyView(PanelLinkButton("Customize") { model.openSettings() }))
                QuickToggleGrid(model: model)
                if model.confirmingEject && !model.volumes.isEmpty {
                    EjectConfirmation(model: model)
                }
                if model.settings.visibleToggles.contains(where: \.restartsFinder) {
                    PanelFootnote(text: "Hide Desktop and Hidden Files restart Finder, which stops any Finder copy in progress.",
                                  systemImage: "arrow.clockwise")
                }
            }

            GrabTextTile(model: model)
                .padding(.top, 4)
        }
    }
}

// MARK: - Keep Awake

private struct KeepAwakeTile: View {
    @ObservedObject var model: ControlsModel
    @State private var pickingTime = false
    @State private var untilTime = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()

    @Environment(\.colorScheme) private var colorScheme

    private var keepAwake: KeepAwakeController { model.keepAwake }

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let accent = PanelStyle.accent(for: colorScheme)
        PanelTile(spacing: 10) {
            HStack(spacing: 10) {
                ToggleGlyph(systemImage: keepAwake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer", isOn: keepAwake.isActive, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Keep Awake").font(.system(size: 13, weight: .semibold))
                    TimelineView(.periodic(from: .now, by: 15)) { context in
                        Text(statusLine(now: context.date))
                            .font(.system(size: 11, weight: keepAwake.isActive ? .medium : .regular))
                            .foregroundStyle(keepAwake.isActive ? accent : style.secondaryInk)
                            .monospacedDigit()
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                PanelSwitch(isOn: keepAwake.isActive, label: "Keep Awake") { keepAwake.toggle() }
            }
            HStack(spacing: 8) {
                PanelMenuButton(title: modeTitle, systemImage: "timer", maxWidth: 210) { modeMenu }
                    .fixedSize()
                Spacer(minLength: 6)
                DisplayAwakeChip(isOn: keepAwake.session?.keepDisplayAwake ?? model.settings.keepDisplayAwake,
                                 isLive: keepAwake.isActive) {
                    keepAwake.setKeepDisplayAwake(!(keepAwake.session?.keepDisplayAwake ?? model.settings.keepDisplayAwake))
                }
            }
            .padding(.leading, 44)
            if pickingTime {
                HStack(spacing: 8) {
                    Text("Until").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                    DatePicker("Until", selection: $untilTime, displayedComponents: .hourAndMinute)
                        .labelsHidden()
                        .datePickerStyle(.field)
                        .controlSize(.small)
                        .fixedSize()
                    Spacer(minLength: 6)
                    Button("Cancel") { pickingTime = false }
                        .controlSize(.small)
                    Button("Start") {
                        let parts = Calendar.current.dateComponents([.hour, .minute], from: untilTime)
                        let date = KeepAwakeMode.nextOccurrence(hour: parts.hour ?? 0, minute: parts.minute ?? 0, after: Date())
                        keepAwake.start(.until(date))
                        pickingTime = false
                    }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.leading, 44)
            }
        }
    }

    private func statusLine(now: Date) -> String {
        KeepAwakeFormat.status(keepAwake.session, now: now, displayHeld: keepAwake.displayHeld)
    }

    /// The running mode, or what the switch would start.
    private var modeTitle: String {
        if let session = keepAwake.session { return session.mode.title(appName: session.appName) }
        return KeepAwakeMode.resumable(model.settings.lastMode, now: Date()).title()
    }

    @ViewBuilder private var modeMenu: some View {
        let current = keepAwake.session?.mode
        Button { keepAwake.start(.indefinitely) } label: { check("Indefinitely", current == .indefinitely) }
        Divider()
        ForEach(KeepAwakeMode.presetDurations, id: \.self) { seconds in
            Button { keepAwake.start(.duration(seconds)) } label: {
                check(KeepAwakeFormat.duration(seconds), current == .duration(seconds))
            }
        }
        let custom = model.settings.customDuration
        if !KeepAwakeMode.presetDurations.contains(custom) {
            Button { keepAwake.start(.duration(custom)) } label: {
                check("Custom: \(KeepAwakeFormat.duration(custom))", current == .duration(custom))
            }
        }
        Divider()
        Button("Until a Time…") { pickingTime = true }
        Menu("While an App Runs") {
            if model.runningApps.isEmpty {
                Text("No apps running")
            }
            ForEach(model.runningApps) { app in
                Button { keepAwake.start(.whileAppRunning(bundleID: app.bundleID)) } label: {
                    check(app.name, current == .whileAppRunning(bundleID: app.bundleID))
                }
            }
        }
        Button { keepAwake.start(.whileDownloading) } label: { check("While Downloading", current == .whileDownloading) }
        Text("macOS may ask to let Orbit see your Downloads folder")
        if keepAwake.isActive {
            Divider()
            Button("Turn Off") { keepAwake.stop() }
        }
    }

    @ViewBuilder private func check(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
}

/// A Control Center–style switch that always draws in the accent colour (AppKit's switch turns grey
/// whenever the panel isn't the key window).
private struct PanelSwitch: View {
    let isOn: Bool
    let label: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Button(action: action) {
            Capsule()
                .fill(isOn ? OrbitTheme.accent : style.trackFill)
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white)
                        .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                        .padding(2)
                }
                .animation(.easeOut(duration: 0.15), value: isOn)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(isOn ? "On" : "Off")
        .help(isOn ? "Turn Keep Awake off" : "Keep your Mac awake")
    }
}

/// "Display" chip beside the mode menu: filled with the accent while a session keeps the display on;
/// while Keep Awake is off it only tints, showing the option the next session will use.
private struct DisplayAwakeChip: View {
    let isOn: Bool
    let isLive: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "display").font(.system(size: 11, weight: .medium))
                Text(isOn ? "Display on" : "Display may sleep").font(.system(size: 12))
            }
            .foregroundStyle(isOn ? (isLive ? Color.white : PanelStyle.accent(for: colorScheme)) : style.inkOnTrack)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(isOn && isLive ? OrbitTheme.accent : style.controlFill))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(isOn ? "Keep Awake also keeps the display on. Click to let it sleep."
                   : "Keep Awake lets the display sleep. Click to keep it on too.")
    }
}

// MARK: - Quick Toggles

private struct QuickToggleGrid: View {
    @ObservedObject var model: ControlsModel

    private let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(model.settings.visibleToggles, id: \.self) { id in
                QuickToggleButton(id: id, display: model.display(id), isBusy: model.busy.contains(id),
                                  isHighlighted: id == .ejectDrives && model.confirmingEject) {
                    model.activate(id)
                }
            }
        }
    }
}

/// One Control Center–style button: a round glyph (accent when on) beside the title and its state.
private struct QuickToggleButton: View {
    let id: QuickToggleID
    let display: QuickToggleDisplay
    let isBusy: Bool
    let isHighlighted: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Button(action: action) {
            HStack(spacing: 9) {
                ToggleGlyph(systemImage: symbol, isOn: display.isOn, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(id.title).font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if isBusy { ProgressView().controlSize(.mini) }
                        Text(isBusy ? "Working…" : display.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(style.secondaryInk)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .frame(height: 48)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tileFill)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isHighlighted ? PanelStyle.accent(for: colorScheme) : style.tileStroke,
                                      lineWidth: isHighlighted ? 1.5 : 0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(display.isAvailable ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!display.isAvailable || isBusy)
        .help(help)
    }

    private var symbol: String {
        switch id {
        case .micMute: display.isOn ? "mic.slash.fill" : "mic.fill"
        case .showHiddenFiles: display.isOn ? "eye.fill" : "eye.slash"
        default: id.symbol
        }
    }

    private var help: String {
        id == .doNotDisturb ? "Runs your Focus Shortcut (choose it in Settings → Controls)." : id.summary
    }
}

/// The round glyph used by Keep Awake and every toggle: accent fill and white icon when on.
private struct ToggleGlyph: View {
    let systemImage: String
    let isOn: Bool
    let size: CGFloat

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : style.inkOnTrack)
            .frame(width: size, height: size)
            .background(Circle().fill(isOn ? OrbitTheme.accent : style.trackFill))
    }
}

/// "Eject 2 drives?" inside the panel, with the drive names and Cancel / Eject.
private struct EjectConfirmation: View {
    @ObservedObject var model: ControlsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                ToggleGlyph(systemImage: "eject.fill", isOn: true, size: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(EjectableVolumeFilter.confirmation(model.volumes)).font(.system(size: 13, weight: .semibold))
                    Text(model.volumes.count == 1 ? "Make sure nothing is still copying to it."
                                                  : model.volumes.map(\.name).joined(separator: ", "))
                        .font(.system(size: 11)).foregroundStyle(style.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Spacer()
                Button("Cancel") { model.confirmingEject = false }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button("Eject") { model.confirmEject() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// A small secondary note under a group of tiles.
private struct PanelFootnote: View {
    let text: String
    let systemImage: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11))
            .foregroundStyle(PanelStyle.colors(for: colorScheme).secondaryInk)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 4)
    }
}

// MARK: - Grab Text

private struct GrabTextTile: View {
    @ObservedObject var model: ControlsModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Button { model.grabText() } label: {
            HStack(spacing: 10) {
                ToggleGlyph(systemImage: "text.viewfinder", isOn: true, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Grab Text").font(.system(size: 13, weight: .semibold))
                    Text(model.screenRecordingGranted ? "Copy text from anywhere on screen"
                                                      : "Asks for Screen Recording the first time")
                        .font(.system(size: 11)).foregroundStyle(style.secondaryInk)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(model.settings.grabTextShortcut.display)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(style.inkOnTrack)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(style.controlFill))
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(style.tileFill)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.tileStroke, lineWidth: 0.5))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Drag over any part of the screen to copy its text. Esc cancels.")
    }
}
