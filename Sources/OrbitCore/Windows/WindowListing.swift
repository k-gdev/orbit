import CoreGraphics
import Foundation

/// What decides whether one of an app's Accessibility windows is listed.
public struct WindowSummary: Sendable, Equatable {
    public var title: String?
    public var size: CGSize
    public var isMinimised: Bool
    /// `kAXSubroleAttribute`: "AXStandardWindow", "AXDialog", "AXFloatingWindow", ... nil when the app doesn't say.
    public var subrole: String?

    public init(title: String?, size: CGSize, isMinimised: Bool, subrole: String?) {
        self.title = title
        self.size = size
        self.isMinimised = isMinimised
        self.subrole = subrole
    }
}

/// Which windows the Dock preview and the Windows tab list, in what order, and under what name.
public enum WindowListing {
    /// Smaller windows (invisible helpers, drag images) are left out.
    public static let minimumSide: CGFloat = 40
    /// Subroles that are real windows. Palettes (`AXFloatingWindow`), system dialogs and the like are not
    /// listed; a window with no subrole is.
    public static let listedSubroles: Set<String> = ["AXStandardWindow", "AXDialog"]

    /// Indices of the windows to list, in the order given (Accessibility reports front to back) with
    /// minimised windows after the rest, or left out when `showMinimised` is off.
    public static func visibleIndices(_ windows: [WindowSummary], showMinimised: Bool) -> [Int] {
        let listed = windows.indices.filter { i in
            let w = windows[i]
            let realKind = w.subrole.map(listedSubroles.contains) ?? true
            return realKind && w.size.width >= minimumSide && w.size.height >= minimumSide
                && (showMinimised || !w.isMinimised)
        }
        return listed.filter { !windows[$0].isMinimised } + listed.filter { windows[$0].isMinimised }
    }

    /// The window's title, or the app's name for an untitled window.
    public static func displayTitle(_ title: String?, appName: String) -> String {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? appName : trimmed
    }
}
