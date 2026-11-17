import OrbitCore
import SwiftUI

/// Every shared panel control in realistic use: a reference for feature authors and the visual check
/// behind `Orbit --snapshot-panel gallery`. Fixture values only; nothing here touches hardware.
struct PanelGallery: View {
    @State private var output = 87.0
    @State private var mic = 100.0
    @State private var micMuted = true
    @State private var chat = 85.0
    @State private var browser = 130.0
    @State private var music = 60.0
    @State private var calls = 70.0
    @State private var callsMuted = true
    @State private var builtIn = 72.0
    @State private var external = 120.0
    @State private var link = false
    @State private var device = "SteelSeries Arctis Nova"

    private let devices = ["SteelSeries Arctis Nova", "MacBook Pro Speakers"]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Output & Input")
            PanelTile {
                HStack {
                    Text("Output").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    PanelMenuButton(title: device, systemImage: "headphones") {
                        ForEach(devices, id: \.self) { name in Button(name) { device = name } }
                    }
                }
                PillSlider(value: $output, scale: .percent, systemImage: "speaker.wave.2.fill", valueText: { "\(Int($0))" })
            }
            PanelTile {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Microphone").font(.system(size: 13, weight: .semibold))
                        Text(micMuted ? "Muted · \(KeyCombo.micMuteDefault.display) to unmute" : "On")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    PanelMenuButton(title: device, systemImage: "mic") { Button(device) {} }
                }
                HStack(spacing: 8) {
                    PillSlider(value: $mic, scale: .percent, isDimmed: micMuted, systemImage: "mic.fill", valueText: { "\(Int($0))" })
                    PanelRoundButton(systemImage: micMuted ? "mic.slash.fill" : "mic.fill", isOn: micMuted) { micMuted.toggle() }
                }
            }

            PanelSectionHeader("Apps", trailing: AnyView(PanelLinkButton("Show all apps") {}))
            appRow("Discord", symbol: "bubble.left.and.bubble.right.fill", tint: Color(red: 0.35, green: 0.40, blue: 0.95),
                   value: $chat, playing: true, routed: false)
            appRow("Google Chrome", symbol: "globe", tint: Color(red: 0.26, green: 0.52, blue: 0.96),
                   value: $browser, playing: true, routed: true)
            appRow("Music", symbol: "music.note", tint: Color(red: 0.98, green: 0.30, blue: 0.40),
                   value: $music, playing: true, routed: false)
            appRow("Slack", symbol: "number", tint: Color(red: 0.29, green: 0.08, blue: 0.29),
                   value: $calls, playing: false, routed: false, muted: $callsMuted)

            PanelSectionHeader("Displays", trailing: AnyView(PanelLinkButton(link ? "Linked" : "Link brightness", systemImage: "link") { link.toggle() }))
            PanelTile {
                displayHeader("MacBook Pro", detail: "Built-in", mode: "1728 × 1117")
                PillSlider(value: $builtIn, scale: .percent, systemImage: "sun.max.fill", valueText: { "\(Int($0))" })
            }
            PanelTile {
                displayHeader("ThinkVision T27", detail: "DDC · up to 150", mode: "2560 × 1440 HiDPI")
                PillSlider(value: $external, scale: PillScale(maximum: 150), systemImage: "sun.max.fill", valueText: { "\(Int($0))" })
            }
        }
    }

    private func appRow(_ name: String, symbol: String, tint: Color, value: Binding<Double>, playing: Bool, routed: Bool,
                        muted: Binding<Bool> = .constant(false)) -> some View {
        HStack(spacing: 8) {
            PillSlider(value: value, scale: PillScale(maximum: 150), height: 34, isDimmed: muted.wrappedValue,
                       leading: AnyView(
                        Image(systemName: symbol).font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))),
                       label: AnyView(HStack(spacing: 6) { Text(name); LevelBars(active: playing && !muted.wrappedValue) }),
                       valueText: { muted.wrappedValue ? "Muted" : "\(Int($0))%" },
                       onLeadingTap: { muted.wrappedValue.toggle() })
            PanelRoundMenu(systemImage: routed ? "laptopcomputer" : "hifispeaker", isHighlighted: routed, size: 34) {
                Text("Play \(name) on")
                Button("Same as Output") {}
                Divider()
                ForEach(devices, id: \.self) { d in Button(d) {} }
            }
        }
    }

    private func displayHeader(_ name: String, detail: String, mode: String) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer()
            PanelMenuButton(title: mode) { Button(mode) {} }
        }
    }
}
