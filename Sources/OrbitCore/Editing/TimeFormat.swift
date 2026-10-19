import Foundation

/// Time labels for the media editors: `m:ss.cc`, or `h:mm:ss.cc` from one hour on.
public enum TimeFormat {
    /// `seconds` rounded to the nearest hundredth. Negative and non-finite values show as zero.
    public static func string(_ seconds: Double) -> String {
        let centis = seconds.isFinite ? Int((max(seconds, 0) * 100).rounded()) : 0
        let hundredths = centis % 100
        let whole = centis / 100
        let s = whole % 60, m = (whole / 60) % 60, h = whole / 3600
        if h > 0 { return String(format: "%d:%02d:%02d.%02d", h, m, s, hundredths) }
        return String(format: "%d:%02d.%02d", m, s, hundredths)
    }
}
