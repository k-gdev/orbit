import AppKit
import OrbitCore
import SwiftUI

/// The Shelf tab of the menu bar panel: a button that opens or closes the floating shelf, and the list of
/// what is on it. Rows drag out like the shelf's own tiles.
struct ShelfPanelView: View {
    @ObservedObject var model: ShelfModel
    /// Opens the floating shelf, or closes it when it is open.
    let toggleShelf: () -> Void
    /// What the "how to open it" hint says (it depends on the shake setting).
    var hint: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Shelf")
            PanelTile {
                HStack(alignment: .center, spacing: 10) {
                    Image(systemName: model.isShelfOpen ? "tray.full.fill" : "tray")
                        .font(.system(size: 18))
                        .foregroundStyle(PanelStyle.accent(for: colorScheme))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.isShelfOpen ? "Shelf is open" : "Shelf is closed")
                            .font(.system(size: 13, weight: .semibold))
                        Text(hint).font(.system(size: 11.5)).foregroundStyle(style.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 6)
                    Button(action: toggleShelf) {
                        Text(model.isShelfOpen ? "Hide" : "Show")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Capsule().fill(OrbitTheme.accent))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            PanelSectionHeader("On the shelf", trailing: model.urls.isEmpty ? nil : AnyView(
                PanelLinkButton("Clear") { model.clear() }))
            if model.urls.isEmpty {
                PanelTile {
                    Text("Nothing here yet. Drop files on the shelf and they wait here until you drag them out.")
                        .font(.system(size: 12))
                        .foregroundStyle(style.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                PanelTile(spacing: 2, padding: 6) {
                    ForEach(model.urls, id: \.self) { url in ShelfListRow(url: url, model: model) }
                }
            }
        }
    }
}

/// One file in the tab's list.
private struct ShelfListRow: View {
    let url: URL
    @ObservedObject var model: ShelfModel

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let offline = model.unreachable.contains(url)
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? Color.primary.opacity(0.08) : Color.clear)
            HStack(spacing: 9) {
                Image(nsImage: ShelfIcon.icon(for: url))
                    .resizable().interpolation(.high).scaledToFit()
                    .frame(width: 28, height: 28)
                    .opacity(offline ? 0.4 : 1)
                    .overlay(alignment: .bottomTrailing) { if offline { ShelfOfflineBadge().scaleEffect(0.8).offset(x: 4, y: 3) } }
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent).font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1).truncationMode(.middle)
                        .opacity(offline ? 0.55 : 1)
                    Text(offline ? "Not connected" : Self.folderName(of: url)).font(.system(size: 11))
                        .foregroundStyle(offline ? Color.orange : style.secondaryInk)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 24)
            }
            .padding(.horizontal, 6)
            ShelfDragSource(urls: offline ? [] : [url],
                            toolTip: offline ? "\(url.path)\n\(ShelfOffline.hint)" : url.path,
                            removeButton: .trailing,
                            onHover: { hovering = $0 },
                            onOpen: { if !offline { NSWorkspace.shared.open(url) } },
                            onRemove: { model.remove(url) },
                            onMovedOut: { model.verifyMoved($0) },
                            menu: { ShelfMenus.entries(for: url, offline: offline, remove: { model.remove(url) },
                                                        trash: { model.moveToTrash(url) }) })
        }
        .frame(height: 40)
    }

    /// "Downloads", the name of the folder the file is in.
    static func folderName(of url: URL) -> String {
        let parent = url.deletingLastPathComponent()
        return parent.lastPathComponent.isEmpty ? parent.path : parent.lastPathComponent
    }
}
