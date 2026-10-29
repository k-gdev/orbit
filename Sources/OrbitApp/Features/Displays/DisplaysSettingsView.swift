import OrbitCore
import SwiftUI

/// Settings → Displays: link and software dimming, a maximum-brightness override per external monitor,
/// and what the resolution menu can and can't offer.
struct DisplaysSettingsView: View {
    @ObservedObject var model: DisplaysModel
    @ObservedObject var settings: DisplaySettings

    init(model: DisplaysModel) {
        self.model = model
        self.settings = model.settings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Brightness") {
                Toggle("Link brightness", isOn: $settings.linkBrightness)
                caption("Moving one display's brightness moves the others by the same proportion.")
                Toggle("Dim displays that don't answer DDC in software", isOn: $settings.useGammaFallback)
                caption("Orbit darkens the picture with the display's colour tables; the backlight itself stays as it is. "
                        + "Turning this off, or quitting Orbit, puts the colours back.")
            }
            SettingsSection("Maximum brightness",
                            footnote: "For monitors that report 100 but accept more over DDC. Past 100 the pill is striped. "
                                + "Auto shows what the monitor reports, or the highest value Orbit has read from it twice in a row, but sends 100 at most: "
                                + "ThinkVisions that go to 150 from their own menu ignore DDC above 100. A fixed maximum is sent as it is.") {
                let externals = model.tiles.filter { !$0.isBuiltIn && !Self.isNative($0.control) }
                if externals.isEmpty {
                    Text("No external displays connected.").foregroundStyle(.secondary)
                }
                ForEach(externals) { tile in
                    MaximumBrightnessRow(model: model, settings: settings, tile: tile)
                    if tile.id != externals.last?.id { Divider() }
                }
            }
            SettingsSection("Resolutions") {
                caption("Each display's pop-up lists every mode macOS offers for it, HiDPI ones included. Orbit doesn't create "
                        + "new HiDPI or virtual modes: those need display overrides in /Library/Displays, which Orbit never writes.")
            }
        }
        .onAppear { model.refreshForSettings() }
    }

    private static func isNative(_ control: BrightnessControl) -> Bool {
        if case .native = control { return true }
        return false
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

/// One monitor: what DDC said, and Auto or a fixed maximum (100...255).
private struct MaximumBrightnessRow: View {
    @ObservedObject var model: DisplaysModel
    @ObservedObject var settings: DisplaySettings
    let tile: DisplaysModel.Tile

    static let range = 100...255
    static let step = 5

    var body: some View {
        let override = settings.maxOverride(for: tile.key)
        let automatic = model.automaticMaximum(for: tile)
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if tile.control == .software || tile.control == .unavailable {
                Text(tile.control == .software ? "Software dimming, 0–100" : "No brightness control")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                if settings.learnedMaximums[tile.key] != nil {
                    Button("Reset learned range") { model.resetLearnedRange(for: tile.key) }
                        .buttonStyle(.link)
                        .help("Forget the boost range Orbit remembered for this monitor; it's learned again after two readings in a row above \(tile.reading?.maximum ?? 100)")
                }
                if override != nil {
                    Button("Auto") { settings.setMaxOverride(nil, for: tile.key) }
                        .buttonStyle(.link)
                        .help("Use what the monitor reports")
                }
                Stepper {
                    Text(override.map(String.init) ?? "Auto\(automatic.map { " (\($0))" } ?? "")")
                        .monospacedDigit()
                        .frame(minWidth: 72, alignment: .trailing)
                } onIncrement: {
                    set((override ?? automatic ?? 100) + Self.step)
                } onDecrement: {
                    set((override ?? automatic ?? 100) - Self.step)
                }
                .help("The most this monitor's pill goes to, and the most Orbit sends it (\(Self.range.lowerBound)–\(Self.range.upperBound)). Auto shows a boost from the monitor's menu but doesn't send it.")
            }
        }
    }

    private var detail: String {
        let learned = settings.learnedMaximums[tile.key].map { " · learned \($0)" } ?? ""
        switch tile.control {
        case .ddc:
            if let reading = tile.reading { return "DDC reports \(reading.current) of \(reading.maximum)\(learned)" }
            return "DDC\(learned)"
        case .probing:
            return (tile.reading.map { "DDC reports \($0.current) of \($0.maximum)" } ?? "Not read yet") + learned
        case .software, .unavailable: return "Doesn't answer DDC"
        case .native: return "Built-in brightness"
        }
    }

    private func set(_ value: Int) {
        settings.setMaxOverride(min(max(value, Self.range.lowerBound), Self.range.upperBound), for: tile.key)
    }
}
