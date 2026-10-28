import SwiftUI

/// A compact capsule pop-up for a tile's header: the current choice ("SteelSeries Arctis Nova",
/// "2560 × 1440 HiDPI") with an up/down chevron; clicking opens a real menu built from `content`
/// (`Button`s, `Picker`s, `Divider`s, `Section`s, `Toggle`s).
///
///     PanelMenuButton(title: device.name, systemImage: "headphones") {
///         ForEach(devices) { d in Button(d.name) { select(d) } }
///     }
struct PanelMenuButton<MenuContent: View>: View {
    let title: String
    var systemImage: String?
    var maxWidth: CGFloat
    @ViewBuilder var content: () -> MenuContent

    @Environment(\.colorScheme) private var colorScheme

    init(title: String, systemImage: String? = nil, maxWidth: CGFloat = 200, @ViewBuilder content: @escaping () -> MenuContent) {
        self.title = title
        self.systemImage = systemImage
        self.maxWidth = maxWidth
        self.content = content
    }

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Menu {
            content()
        } label: {
            HStack(spacing: 5) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
                }
                Text(title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(style.secondaryInk)
            }
            .foregroundStyle(style.inkOnTrack)
            .padding(.leading, 9).padding(.trailing, 7).padding(.vertical, 4)
            .background(Capsule().fill(style.controlFill))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(maxWidth: maxWidth, alignment: .trailing)
        .help(title)
    }
}
