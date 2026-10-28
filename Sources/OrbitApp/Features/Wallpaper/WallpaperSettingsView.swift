import OrbitCore
import SwiftUI

/// Wallpaper's Settings page: each display's wallpaper (unplugged ones too), the pause preferences, the still frame
/// switch, and the downloaded aerials.
struct WallpaperSettingsView: View {
    @ObservedObject var model: WallpaperModel
    @ObservedObject var settings: WallpaperSettings

    init(model: WallpaperModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Displays", footnote: "Each display plays its wallpaper behind the desktop icons, on every Space. "
                            + "An unplugged display keeps its wallpaper for when it comes back.") {
                if model.displays.isEmpty {
                    Text("No displays found.").foregroundStyle(.secondary)
                }
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { Divider() }
                    WallpaperSettingsRow(model: model, display: display)
                }
            }

            SettingsSection("Playback", footnote: "Wallpapers always pause while a full-screen app or window covers the display, "
                            + "while the screen is locked and while the displays sleep. They are always muted.") {
                Toggle("Pause on battery power", isOn: $settings.pauseOnBattery)
                Toggle("Pause in Low Power Mode", isOn: $settings.pauseInLowPower)
            }

            SettingsSection("Desktop picture", footnote: "Mission Control and switching Spaces show the normal desktop picture, "
                            + "so Orbit sets it to a frame of the wallpaper. When you remove a wallpaper or turn Wallpaper off, "
                            + "Orbit puts back the picture you had, unless you chose another one since.") {
                Toggle("Use a still of the wallpaper as the desktop picture", isOn: $settings.setStillFrame)
            }

            SettingsSection("Apple aerials", footnote: "Orbit plays the aerials macOS has already downloaded and never downloads "
                            + "any itself. Download more in System Settings › Wallpaper.") {
                if model.aerials.isEmpty {
                    Text("No aerials downloaded yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.aerialGroups, id: \.title) { group in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(group.title).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
                            Text(group.aerials.map(\.name).joined(separator: ", "))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Button("Open Wallpaper Settings…") { model.openWallpaperSettings() }
            }
        }
    }
}

/// One display in Settings: preview, name, what it plays and its status, and the Choose… menu.
struct WallpaperSettingsRow: View {
    @ObservedObject var model: WallpaperModel
    let display: WallpaperDisplayItem

    var body: some View {
        let source = model.source(for: display)
        let status = model.status(for: display)
        HStack(spacing: 12) {
            WallpaperPreview(image: source.flatMap(model.thumbnail(for:)), source: source, status: status)
                .frame(width: 80, height: 45)
                .opacity(display.isConnected ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(display.name).fontWeight(.medium)
                    Text(display.detail).font(.caption).foregroundStyle(.secondary)
                }
                Text(source.map { "\(model.title(for: $0)) · \(model.kind(of: $0))" } ?? "No wallpaper")
                    .lineLimit(1)
                WallpaperStatusLine(status: status, kind: nil)
            }
            Spacer(minLength: 8)
            Menu("Choose…") {
                WallpaperChooseMenu(model: model, display: display)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}
