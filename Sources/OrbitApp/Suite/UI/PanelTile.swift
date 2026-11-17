import SwiftUI

/// The menu bar panel's colours for light and dark. Read them through `PanelStyle.colors(for:)` with the
/// view's `colorScheme`, so every feature's tiles, pills and buttons match.
struct PanelStyle {
    /// Tile background: translucent white in light, white 8 % in dark.
    let tileFill: Color
    let tileStroke: Color
    /// The unfilled part of a pill track, and the resting fill of round buttons.
    let trackFill: Color
    /// The filled part of a pill.
    let pillFill: Color
    /// Icon and text colour over the unfilled track / over the pill fill.
    let inkOnTrack: Color
    let inkOnFill: Color
    /// Background of compact controls (menu buttons) sitting on a tile.
    let controlFill: Color
    /// Secondary text (section headers, subtitles).
    let secondaryInk: Color

    static func colors(for scheme: ColorScheme) -> PanelStyle {
        scheme == .dark ? dark : light
    }

    /// The accent for text and icons on the panel: `OrbitTheme.accent` in light; in dark, the same hue
    /// lifted 50 % towards white so it stays readable on dark glass.
    @MainActor static func accent(for scheme: ColorScheme) -> Color {
        guard scheme == .dark else { return OrbitTheme.accent }
        let c = OrbitTheme.accentRGBA
        func lift(_ v: Double) -> Double { v + (1 - v) * 0.5 }
        return Color(.sRGB, red: lift(c.r), green: lift(c.g), blue: lift(c.b), opacity: 1)
    }

    static let light = PanelStyle(
        tileFill: Color.white.opacity(0.72), tileStroke: Color.black.opacity(0.06),
        trackFill: Color.black.opacity(0.08), pillFill: .white,
        inkOnTrack: Color(red: 0.30, green: 0.28, blue: 0.34), inkOnFill: Color(red: 0.24, green: 0.22, blue: 0.27),
        controlFill: Color.black.opacity(0.05), secondaryInk: Color(red: 0.34, green: 0.32, blue: 0.37))

    static let dark = PanelStyle(
        tileFill: Color.white.opacity(0.08), tileStroke: Color.white.opacity(0.07),
        trackFill: Color.white.opacity(0.12), pillFill: Color.white.opacity(0.85),
        inkOnTrack: Color.white.opacity(0.88), inkOnFill: Color.black.opacity(0.74),
        controlFill: Color.white.opacity(0.10), secondaryInk: Color.white.opacity(0.62))
}

/// A rounded translucent card holding one group of controls in the menu bar panel (one display, the
/// output device, a clipboard entry). Full width of the panel content; 12 pt corners, 10 pt padding.
///
///     PanelTile {
///         HStack { Text("MacBook Pro").font(.system(size: 13, weight: .semibold)); Spacer(); PanelMenuButton(...) }
///         PillSlider(value: $brightness, scale: .percent, systemImage: "sun.max.fill", valueText: { "\(Int($0))" })
///     }
struct PanelTile<Content: View>: View {
    var spacing: CGFloat = 9
    var padding: CGFloat = 10
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var colorScheme

    init(spacing: CGFloat = 9, padding: CGFloat = 10, @ViewBuilder content: @escaping () -> Content) {
        self.spacing = spacing
        self.padding = padding
        self.content = content
    }

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        VStack(alignment: .leading, spacing: spacing) { content() }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(style.tileFill)
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(style.tileStroke, lineWidth: 0.5))
            )
    }
}

/// A small-caps section title above a group of tiles ("OUTPUT & INPUT", "APPS"), with an optional
/// trailing control such as a "Show all apps" link (`PanelLinkButton`).
struct PanelSectionHeader: View {
    let title: String
    let trailing: AnyView?

    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, trailing: AnyView? = nil) {
        self.title = title
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(PanelStyle.colors(for: colorScheme).secondaryInk)
            Spacer(minLength: 8)
            if let trailing { trailing }
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }
}

/// A borderless accent-coloured text button for section headers ("Show all apps", "Link brightness").
struct PanelLinkButton: View {
    let title: String
    var systemImage: String?
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, systemImage: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).font(.system(size: 10, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(PanelStyle.accent(for: colorScheme))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
