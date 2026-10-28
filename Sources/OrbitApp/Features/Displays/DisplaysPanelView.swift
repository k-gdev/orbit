import AppKit
import OrbitCore
import SwiftUI

/// The Displays tab (mockup: Displays): a header with Link brightness, then one tile per display with its
/// name, how its brightness is driven, a resolution pop-up and a brightness pill (striped past 100 for
/// monitors that go further, like Kevo's ThinkVisions up to 150).
struct DisplaysPanelView: View {
    @ObservedObject var model: DisplaysModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Displays", trailing: AnyView(linkButton))
            if model.tiles.isEmpty {
                PanelTile {
                    Text(model.hasScanned ? "No displays found." : "Looking for displays…")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(model.tiles) { tile in
                DisplayTileView(model: model, tile: tile)
            }
        }
    }

    private var linkButton: some View {
        let linked = model.settings.linkBrightness
        return PanelLinkButton(linked ? "Linked" : "Link brightness", systemImage: linked ? "link.circle.fill" : "link") {
            model.setLinked(!linked)
        }
        .help(linked ? "Brightness moves on every display together. Click to unlink."
                     : "Move every display's brightness together, proportionally.")
    }
}

private struct DisplayTileView: View {
    @ObservedObject var model: DisplaysModel
    let tile: DisplaysModel.Tile

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(tile.title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                    Text(model.caption(for: tile)).font(.system(size: 11)).foregroundStyle(style.secondaryInk).lineLimit(1)
                }
                Spacer(minLength: 8)
                DisplayModeMenu(model: model, tile: tile)
            }
            if tile.control.hasPill {
                let range = model.range(for: tile)
                PillSlider(value: Binding(get: { model.brightness(of: tile.id) }, set: { model.setBrightness($0, for: tile.id) }),
                           scale: range.scale, isDimmed: tile.control == .probing,
                           systemImage: tile.control == .software ? "sun.min.fill" : "sun.max.fill",
                           valueText: { "\(Int($0.rounded()))" },
                           onEditingEnded: { model.endEditing() })
                    .help(help)
            } else {
                Text("Turn on DDC/CI in the monitor's own menu, or software dimming in Settings.")
                    .font(.system(size: 11)).foregroundStyle(style.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var help: String {
        switch tile.control {
        case .native: "Brightness of \(tile.title)"
        case .ddc: model.range(for: tile).isBoostable
            ? "Brightness over DDC. Past \(model.range(for: tile).nominalMaximum) is the monitor's boost range."
            : "Brightness over DDC"
        case .software: "This monitor doesn't answer DDC, so Orbit darkens the picture instead (the backlight stays as it is)."
        case .probing: "Asking the monitor for its brightness…"
        case .unavailable: ""
        }
    }
}

/// The resolution pop-up: HiDPI sizes first, then standard ones, largest first; a size with several
/// refresh rates opens a submenu of rates. The current mode is ticked.
private struct DisplayModeMenu: View {
    @ObservedObject var model: DisplaysModel
    let tile: DisplaysModel.Tile

    var body: some View {
        let groups = tile.modes.groups
        let hiDPI = groups.filter(\.isHiDPI)
        let standard = groups.filter { !$0.isHiDPI }
        PanelMenuButton(title: tile.modes.title, maxWidth: 190) {
            if groups.isEmpty {
                Text("No resolutions reported")
            }
            ForEach(hiDPI) { group in item(group) }
            if !hiDPI.isEmpty, !standard.isEmpty { Divider() }
            ForEach(standard) { group in item(group) }
            Divider()
            Button("Displays Settings…") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") { NSWorkspace.shared.open(url) }
            }
        }
    }

    @ViewBuilder private func item(_ group: DisplayModeGroup) -> some View {
        if group.entries.count == 1, let entry = group.entries.first {
            choice(entry, title: group.sizeLabel)
        } else {
            Menu {
                ForEach(group.entries) { entry in choice(entry, title: entry.refreshLabel ?? entry.label) }
            } label: {
                if group.isCurrent { Label(group.sizeLabel, systemImage: "checkmark") } else { Text(group.sizeLabel) }
            }
        }
    }

    private func choice(_ entry: DisplayModeEntry, title: String) -> some View {
        Toggle(title, isOn: Binding(get: { entry.isCurrent }, set: { _ in model.select(entry, for: tile.id) }))
    }
}
