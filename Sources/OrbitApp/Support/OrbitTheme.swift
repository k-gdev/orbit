import Combine
import Foundation
import Observation
import OrbitCore
import SwiftUI

/// The one place the accent colour lives. `bind(to:)` follows `SettingsStore.accentHex`, so changing the
/// setting recolours every view that reads `OrbitTheme.accent` the next time its body runs (Observation
/// tracks the read, including through the static accessors below).
@MainActor @Observable
final class OrbitTheme {
    static let shared = OrbitTheme()

    private(set) var accentRGBA: RGBA
    private(set) var accentColor: Color
    @ObservationIgnored private var subscription: AnyCancellable?

    private init() {
        let rgba = Self.fallback
        accentRGBA = rgba
        accentColor = rgba.color
    }

    private static var fallback: RGBA {
        HexColor.parse(SettingsStore.defaultAccentHex) ?? RGBA(r: 0.502, g: 0.392, b: 0.612, a: 1)
    }

    /// Follows `settings.accentHex` from now on (and applies the current value immediately).
    func bind(to settings: SettingsStore) {
        subscription = settings.$accentHex
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hex in self?.apply(hex: hex) }
        apply(hex: settings.accentHex)
    }

    func apply(hex: String) {
        let rgba = HexColor.parse(hex) ?? Self.fallback
        guard rgba != accentRGBA else { return }
        accentRGBA = rgba
        accentColor = rgba.color
    }

    /// Shorthands for call sites; reading them inside a view body subscribes the view to changes.
    static var accent: Color { shared.accentColor }
    static var accentRGBA: RGBA { shared.accentRGBA }
    /// A darker shade of the accent for thin markers (playhead, waveform cut lines) over light content.
    static var accentMarker: Color {
        let c = shared.accentRGBA
        return Color(.sRGB, red: c.r * 0.75, green: c.g * 0.75, blue: c.b * 0.75, opacity: 1)
    }
}
