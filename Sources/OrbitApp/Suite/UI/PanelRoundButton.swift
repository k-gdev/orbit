import SwiftUI

/// A small round icon button beside a pill (mic mute, link, a per-row action). `isOn` fills it with the
/// accent colour and turns the icon white. 28 pt by default; app rows use 34 to match their pills.
struct PanelRoundButton: View {
    let systemImage: String
    var isOn: Bool
    var size: CGFloat
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled

    init(systemImage: String, isOn: Bool = false, size: CGFloat = 28, action: @escaping () -> Void) {
        self.systemImage = systemImage
        self.isOn = isOn
        self.size = size
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            PanelRoundFace(systemImage: systemImage, isOn: isOn, isHighlighted: false, size: size, style: PanelStyle.colors(for: colorScheme))
                .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
    }
}

/// A round button that opens a menu (an app's output device picker). `isHighlighted` draws an accent
/// ring, for "this row has a non-default choice".
struct PanelRoundMenu<MenuContent: View>: View {
    let systemImage: String
    var isHighlighted: Bool
    var size: CGFloat
    @ViewBuilder var content: () -> MenuContent

    @Environment(\.colorScheme) private var colorScheme

    init(systemImage: String, isHighlighted: Bool = false, size: CGFloat = 28, @ViewBuilder content: @escaping () -> MenuContent) {
        self.systemImage = systemImage
        self.isHighlighted = isHighlighted
        self.size = size
        self.content = content
    }

    var body: some View {
        Menu {
            content()
        } label: {
            PanelRoundFace(systemImage: systemImage, isOn: false, isHighlighted: isHighlighted, size: size,
                           style: PanelStyle.colors(for: colorScheme))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

private struct PanelRoundFace: View {
    let systemImage: String
    let isOn: Bool
    let isHighlighted: Bool
    let size: CGFloat
    let style: PanelStyle

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(isOn ? Color.white : (isHighlighted ? OrbitTheme.accent : style.inkOnTrack))
            .frame(width: size, height: size)
            .background(Circle().fill(isOn ? OrbitTheme.accent : style.trackFill))
            .overlay(Circle().strokeBorder(OrbitTheme.accent, lineWidth: isHighlighted ? 1.5 : 0))
            .contentShape(Circle())
    }
}
