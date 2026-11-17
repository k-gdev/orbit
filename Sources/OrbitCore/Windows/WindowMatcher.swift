import CoreGraphics

/// What Orbit knows about one window from one source (Accessibility or ScreenCaptureKit), enough to tell
/// whether two reads describe the same window. `frame` is in global screen coordinates with the origin at
/// the top left of the primary display (the space both AX and ScreenCaptureKit report in).
public struct WindowDescriptor: Sendable, Equatable {
    /// The window server's window number (`CGWindowID`), when the source knows it. ScreenCaptureKit always
    /// does; Accessibility only through the private `_AXUIElementGetWindow`.
    public var number: Int?
    /// The window title. nil and "" are treated alike (ScreenCaptureKit has no titles without Screen Recording).
    public var title: String?
    public var frame: CGRect

    public init(number: Int?, title: String?, frame: CGRect) {
        self.number = number
        self.title = title
        self.frame = frame
    }
}

/// Pairs an app's Accessibility windows (which can be raised, minimised and closed) with its
/// ScreenCaptureKit windows (which can be captured as thumbnails).
public enum WindowMatcher {
    /// How far apart (in points, per edge) two frames may be and still be the same window.
    public static let frameTolerance: CGFloat = 2

    /// Index pairs `(ax, capture)`, sorted by `ax`; each index appears at most once.
    ///
    /// When both sides know the window number, the number decides: equal numbers match, different numbers
    /// never do (whatever the titles and frames say). Otherwise the windows match when their titles are equal
    /// and every edge of their frames is within `frameTolerance`; among several such candidates the closest
    /// frame wins.
    public static func match(axWindows: [WindowDescriptor], captureWindows: [WindowDescriptor]) -> [(ax: Int, capture: Int)] {
        var used = Set<Int>()
        var result: [(ax: Int, capture: Int)] = []
        var unmatched: [Int] = []

        for (i, ax) in axWindows.enumerated() {
            if let number = ax.number,
               let j = captureWindows.indices.first(where: { !used.contains($0) && captureWindows[$0].number == number }) {
                used.insert(j)
                result.append((ax: i, capture: j))
            } else {
                unmatched.append(i)
            }
        }

        for i in unmatched {
            let ax = axWindows[i]
            let candidates = captureWindows.indices.filter { j in
                let capture = captureWindows[j]
                return !used.contains(j)
                    && (ax.number == nil || capture.number == nil)
                    && (ax.title ?? "") == (capture.title ?? "")
                    && isWithinTolerance(ax.frame, capture.frame)
            }
            if let best = candidates.min(by: { deviation(ax.frame, captureWindows[$0].frame) < deviation(ax.frame, captureWindows[$1].frame) }) {
                used.insert(best)
                result.append((ax: i, capture: best))
            }
        }
        return result.sorted { $0.ax < $1.ax }
    }

    /// Whether every edge of `a` is within `frameTolerance` of the same edge of `b`.
    public static func isWithinTolerance(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.maxX - b.maxX) <= frameTolerance
            && abs(a.minY - b.minY) <= frameTolerance && abs(a.maxY - b.maxY) <= frameTolerance
    }

    private static func deviation(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.maxX - b.maxX) + abs(a.minY - b.minY) + abs(a.maxY - b.maxY)
    }
}
