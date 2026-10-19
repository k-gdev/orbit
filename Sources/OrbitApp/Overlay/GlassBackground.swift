import SwiftUI

/// How glass surfaces draw. `.live` uses Liquid Glass (macOS 26+) or the system
/// material; `.flat` is a plain translucent fill for offscreen snapshots, where
/// materials and glass don't render.
enum GlassRendering {
    case live, flat
}

private struct GlassRenderingKey: EnvironmentKey {
    static let defaultValue = GlassRendering.live
}

extension EnvironmentValues {
    var glassRendering: GlassRendering {
        get { self[GlassRenderingKey.self] }
        set { self[GlassRenderingKey.self] = newValue }
    }
}

/// Translucent glass filling `shape`, which is laid out in this view's bounds.
/// `tintOpacity` is the strength of the white tint (0.18 for petals).
struct GlassBackground<S: Shape>: View {
    let shape: S
    var tintOpacity = 0.18

    @Environment(\.glassRendering) private var rendering
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        switch rendering {
        case .flat:
            let dark = colorScheme == .dark
            shape.fill(dark ? Color(white: 0.17).opacity(0.44 + tintOpacity) : Color.white.opacity(0.42 + tintOpacity))
                .overlay(shape.stroke(Color.white.opacity(dark ? 0.12 : 0.45), lineWidth: 0.5))
        case .live:
            if #available(macOS 26, *) {
                Color.clear.glassEffect(.regular.tint(.white.opacity(tintOpacity)), in: shape)
            } else {
                Color.clear
                    .background(.ultraThinMaterial, in: shape)
                    .overlay(shape.fill(Color.white.opacity(0.12)))
            }
        }
    }
}
