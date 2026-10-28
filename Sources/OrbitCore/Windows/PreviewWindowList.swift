import CoreGraphics
import Foundation

/// One window as Accessibility reports it (what decides listing, and what matching needs).
public struct AccessibilityWindowInfo: Sendable, Equatable {
    public var number: Int?
    public var title: String?
    /// Top-left global coordinates.
    public var frame: CGRect
    public var isMinimised: Bool
    public var subrole: String?

    public init(number: Int?, title: String?, frame: CGRect, isMinimised: Bool, subrole: String?) {
        self.number = number
        self.title = title
        self.frame = frame
        self.isMinimised = isMinimised
        self.subrole = subrole
    }

    public var descriptor: WindowDescriptor { WindowDescriptor(number: number, title: title, frame: frame) }
    public var summary: WindowSummary { WindowSummary(title: title, size: frame.size, isMinimised: isMinimised, subrole: subrole) }
}

/// One window as ScreenCaptureKit reports it (`SCWindow`): it sees every Space, Accessibility does not.
public struct CaptureWindowInfo: Sendable, Equatable {
    public var number: Int
    public var title: String?
    /// Top-left global coordinates.
    public var frame: CGRect
    /// On screen now. Windows on other Spaces, in another app's full screen, or minimised are not.
    public var isOnScreen: Bool
    /// The window layer; 0 for normal windows.
    public var layer: Int

    public init(number: Int, title: String?, frame: CGRect, isOnScreen: Bool, layer: Int) {
        self.number = number
        self.title = title
        self.frame = frame
        self.isOnScreen = isOnScreen
        self.layer = layer
    }

    public var descriptor: WindowDescriptor { WindowDescriptor(number: number, title: title, frame: frame) }
}

/// One window in the Dock preview: an Accessibility window (which can be raised), with its capture window
/// when one matched (for the thumbnail), or a capture-only window seen elsewhere.
public struct PreviewWindowEntry: Sendable, Equatable {
    /// Index into the Accessibility windows; nil for a window only ScreenCaptureKit sees.
    public var accessibilityIndex: Int?
    /// Index into the capture windows; nil when none matched (or no Screen Recording).
    public var captureIndex: Int?
    public var title: String?
    public var frame: CGRect
    public var isMinimised: Bool

    public init(accessibilityIndex: Int?, captureIndex: Int?, title: String?, frame: CGRect, isMinimised: Bool) {
        self.accessibilityIndex = accessibilityIndex
        self.captureIndex = captureIndex
        self.title = title
        self.frame = frame
        self.isMinimised = isMinimised
    }

    /// On another Space or in full screen: Accessibility can't reach it, so choosing it activates the app
    /// (macOS then switches to a Space with its windows).
    public var isElsewhere: Bool { accessibilityIndex == nil }
}

/// The Dock preview's window list. Accessibility lists only the current Space's windows plus minimised
/// ones; with Screen Recording, ScreenCaptureKit sees every Space. This puts the listed Accessibility
/// windows first (`WindowListing` order, each paired with its capture window by `WindowMatcher`), then the
/// capture windows that are off screen, unmatched and look like real windows: layer 0, at least
/// `WindowListing.minimumSide` on each side, and titled (untitled off-screen windows are nearly always
/// helpers). Matching runs against every Accessibility window, listed or not, so a palette or a hidden
/// minimised window never comes back as an "elsewhere" window.
public enum PreviewWindowList {
    public static func merge(accessibility: [AccessibilityWindowInfo], capture: [CaptureWindowInfo],
                             showMinimised: Bool) -> [PreviewWindowEntry] {
        let pairs = WindowMatcher.match(axWindows: accessibility.map(\.descriptor), captureWindows: capture.map(\.descriptor))
        var captureFor: [Int: Int] = [:]
        for pair in pairs { captureFor[pair.ax] = pair.capture }
        let matched = Set(captureFor.values)

        let listed = WindowListing.visibleIndices(accessibility.map(\.summary), showMinimised: showMinimised).map { i in
            PreviewWindowEntry(accessibilityIndex: i, captureIndex: captureFor[i], title: accessibility[i].title,
                               frame: accessibility[i].frame, isMinimised: accessibility[i].isMinimised)
        }
        let elsewhere = capture.indices.filter { j in
            let window = capture[j]
            let titled = !(window.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return !matched.contains(j) && !window.isOnScreen && window.layer == 0 && titled
                && window.frame.width >= WindowListing.minimumSide && window.frame.height >= WindowListing.minimumSide
        }.map { j in
            PreviewWindowEntry(accessibilityIndex: nil, captureIndex: j, title: capture[j].title,
                               frame: capture[j].frame, isMinimised: false)
        }
        return listed + elsewhere
    }
}
