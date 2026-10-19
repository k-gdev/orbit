import Foundation

/// Six-digit hex colours (`80649C`, `#80649c`) to and from `RGBA`. Pure, so it is testable without UI.
public struct HexColor {
    /// Parses exactly six hex digits, with or without a leading `#`, in either case. Anything else is nil.
    public static func parse(_ text: String) -> RGBA? {
        var digits = Substring(text)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        guard digits.count == 6, digits.allSatisfy(\.isHexDigit), digits.allSatisfy(\.isASCII), let value = UInt32(digits, radix: 16) else { return nil }
        return RGBA(r: Double((value >> 16) & 0xFF) / 255,
                    g: Double((value >> 8) & 0xFF) / 255,
                    b: Double(value & 0xFF) / 255,
                    a: 1)
    }

    /// `RRGGBB` in upper case, no `#`. Alpha is ignored; channels are clamped to 0...1.
    public static func format(_ color: RGBA) -> String {
        func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "%02X%02X%02X", byte(color.r), byte(color.g), byte(color.b))
    }
}
