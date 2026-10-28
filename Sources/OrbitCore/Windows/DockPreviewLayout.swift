import CoreGraphics

/// Which screen edge the Dock sits on.
public enum DockEdge: String, Sendable, CaseIterable {
    case bottom, left, right

    /// From the Dock's `orientation` preference (`com.apple.dock`): "left" and "right" as written, anything
    /// else (including no value, the default) is the bottom.
    public init(orientation: String?) {
        switch orientation {
        case "left": self = .left
        case "right": self = .right
        default: self = .bottom
        }
    }
}

/// A bitmap size in pixels.
public struct PixelSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Converts between the two global screen spaces macOS uses: Accessibility, ScreenCaptureKit and Core
/// Graphics measure from the TOP left of the primary display (y down); AppKit windows and `NSEvent.mouseLocation`
/// from its BOTTOM left (y up). The same flip goes both ways.
public enum ScreenSpace {
    /// `rect` in the other space. `primaryHeight` is the primary display's height in points.
    public static func flip(_ rect: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    public static func flip(_ point: CGPoint, primaryHeight: CGFloat) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

/// The geometry of the Dock preview: a glass strip beside the hovered Dock icon (above it for a bottom Dock,
/// to its right or left for a side Dock) holding a title line and one thumbnail per window. Thumbnails are
/// as tall as possible up to `maxThumbnailHeight`, in one row when they fit and in several rows when one row
/// would shrink them, and the strip stays `screenMargin` inside the screen's visible frame.
public struct DockPreviewLayout: Sendable, Equatable {
    public static let maxThumbnailHeight: CGFloat = 140
    /// Between thumbnails, and between rows.
    public static let spacing: CGFloat = 10
    /// Inside the strip, around the title line and the thumbnails.
    public static let padding: CGFloat = 10
    /// The title line (app name, or the hovered window's title).
    public static let headerHeight: CGFloat = 18
    public static let headerGap: CGFloat = 8
    /// Between the Dock icon and the strip.
    public static let iconGap: CGFloat = 8
    public static let screenMargin: CGFloat = 8
    /// The narrowest content area, so a single narrow window still leaves room for its title.
    public static let minContentWidth: CGFloat = 160
    /// How far outside the strip and icon the pointer may stray before the preview closes.
    public static let hoverSlack: CGFloat = 6
    /// Used for a window whose size is unknown or zero.
    public static let defaultAspectRatio: CGFloat = 1.6
    /// Very wide or tall windows (toolbars, palettes) are drawn within this aspect range.
    public static let aspectRatioRange: ClosedRange<CGFloat> = 0.5...3

    /// The strip in AppKit screen coordinates (origin at the primary display's bottom left, y up).
    public var stripFrame: CGRect
    /// The title line inside the strip; origin at the strip's top left, y down (SwiftUI's space).
    public var headerFrame: CGRect
    /// One frame per window, in the order given, inside the strip (top-left origin, y down).
    public var thumbnailFrames: [CGRect]
    /// The hovered Dock icon, AppKit coordinates.
    public var iconFrame: CGRect
    public var edge: DockEdge

    /// The layout for windows with these width ÷ height ratios, next to `iconFrame` (AppKit coordinates)
    /// on a Dock at `edge`, inside `visibleFrame` (the icon's screen, `NSScreen.visibleFrame`). nil for no
    /// windows.
    public static func make(aspectRatios: [CGFloat], iconFrame icon: CGRect, edge: DockEdge,
                            visibleFrame visible: CGRect) -> DockPreviewLayout? {
        guard !aspectRatios.isEmpty else { return nil }
        let aspects = aspectRatios.map(sanitizedAspectRatio)
        let chrome = 2 * padding + headerHeight + headerGap
        let margin = screenMargin

        let availableWidth: CGFloat
        let availableHeight: CGFloat
        switch edge {
        case .bottom:
            availableWidth = visible.width - 2 * margin - 2 * padding
            availableHeight = (visible.maxY - margin) - max(icon.maxY + iconGap, visible.minY + margin) - chrome
        case .left:
            availableWidth = (visible.maxX - margin) - max(icon.maxX + iconGap, visible.minX + margin) - 2 * padding
            availableHeight = visible.height - 2 * margin - chrome
        case .right:
            availableWidth = min(icon.minX - iconGap, visible.maxX - margin) - (visible.minX + margin) - 2 * padding
            availableHeight = visible.height - 2 * margin - chrome
        }
        let (rows, height) = bestRows(aspects, availableWidth: max(availableWidth, 1), availableHeight: max(availableHeight, 1))

        let rowWidths = rows.map { row in row.reduce(0) { $0 + aspects[$1] * height } + spacing * CGFloat(row.count - 1) }
        let contentWidth = max(rowWidths.max() ?? 0, minContentWidth)
        let contentHeight = CGFloat(rows.count) * height + spacing * CGFloat(rows.count - 1)
        let size = CGSize(width: contentWidth + 2 * padding, height: chrome + contentHeight)

        var frames = [CGRect](repeating: .zero, count: aspects.count)
        var y = padding + headerHeight + headerGap
        for (r, row) in rows.enumerated() {
            var x = padding + (contentWidth - rowWidths[r]) / 2
            for i in row {
                let width = aspects[i] * height
                frames[i] = CGRect(x: x, y: y, width: width, height: height)
                x += width + spacing
            }
            y += height + spacing
        }

        var origin: CGPoint
        switch edge {
        case .bottom: origin = CGPoint(x: icon.midX - size.width / 2, y: icon.maxY + iconGap)
        case .left: origin = CGPoint(x: icon.maxX + iconGap, y: icon.midY - size.height / 2)
        case .right: origin = CGPoint(x: icon.minX - iconGap - size.width, y: icon.midY - size.height / 2)
        }
        origin.x = clamp(origin.x, visible.minX + margin, visible.maxX - margin - size.width)
        origin.y = clamp(origin.y, visible.minY + margin, visible.maxY - margin - size.height)

        return DockPreviewLayout(stripFrame: CGRect(origin: origin, size: size),
                                 headerFrame: CGRect(x: padding, y: padding, width: contentWidth, height: headerHeight),
                                 thumbnailFrames: frames, iconFrame: icon, edge: edge)
    }

    /// Whether the pointer (AppKit coordinates) is over the strip, the icon, or the gap between them, give
    /// or take `hoverSlack`. Outside all three the preview closes.
    public func hoverRegionContains(_ point: CGPoint) -> Bool {
        let slack = Self.hoverSlack
        return stripFrame.insetBy(dx: -slack, dy: -slack).contains(point)
            || iconFrame.insetBy(dx: -slack, dy: -slack).contains(point)
            || bridge.insetBy(dx: -slack, dy: -slack).contains(point)
    }

    /// The gap between icon and strip, as wide as the icon.
    private var bridge: CGRect {
        switch edge {
        case .bottom:
            CGRect(x: iconFrame.minX, y: iconFrame.maxY, width: iconFrame.width, height: max(stripFrame.minY - iconFrame.maxY, 0))
        case .left:
            CGRect(x: iconFrame.maxX, y: iconFrame.minY, width: max(stripFrame.minX - iconFrame.maxX, 0), height: iconFrame.height)
        case .right:
            CGRect(x: stripFrame.maxX, y: iconFrame.minY, width: max(iconFrame.minX - stripFrame.maxX, 0), height: iconFrame.height)
        }
    }

    /// The bitmap size to capture a window at for its thumbnail: the shown height (at most
    /// `maxThumbnailHeight`, never more than the window's own height) times the display `scale`.
    public static func capturePixelSize(for windowSize: CGSize, scale: CGFloat) -> PixelSize {
        let aspect = sanitizedAspectRatio(windowSize.height > 0 ? windowSize.width / windowSize.height : 0)
        let points = min(maxThumbnailHeight, max(windowSize.height, 0))
        let height = max(1, Int((points * scale).rounded()))
        let width = max(1, Int((CGFloat(height) * aspect).rounded()))
        return PixelSize(width: width, height: height)
    }

    /// `ratio` limited to `aspectRatioRange`; `defaultAspectRatio` for zero, negative or non-finite values.
    public static func sanitizedAspectRatio(_ ratio: CGFloat) -> CGFloat {
        guard ratio.isFinite, ratio > 0 else { return defaultAspectRatio }
        return min(max(ratio, aspectRatioRange.lowerBound), aspectRatioRange.upperBound)
    }

    // MARK: Rows

    /// The row split giving the tallest thumbnails (fewest rows on a tie), and that height.
    private static func bestRows(_ aspects: [CGFloat], availableWidth: CGFloat, availableHeight: CGFloat) -> (rows: [[Int]], height: CGFloat) {
        var best: (rows: [[Int]], height: CGFloat) = ([Array(aspects.indices)], 0)
        var first = true
        for count in 1...aspects.count {
            let rows = partition(aspects, into: count)
            let byWidth = rows.map { row in
                (availableWidth - spacing * CGFloat(row.count - 1)) / row.reduce(0) { $0 + aspects[$1] }
            }.min() ?? 0
            let byHeight = (availableHeight - spacing * CGFloat(rows.count - 1)) / CGFloat(rows.count)
            let height = min(maxThumbnailHeight, byWidth, byHeight)
            if first || height > best.height + 0.5 { best = (rows, height) }
            first = false
            // More rows can't help once one row is already at full height, or rows are limited by height.
            if byWidth >= maxThumbnailHeight || byHeight <= best.height { break }
        }
        return (best.rows, max(best.height, 1))
    }

    /// Splits the windows, in order, into about `count` rows of similar total width (each window goes to the
    /// row its centre falls in). Empty rows are dropped.
    private static func partition(_ aspects: [CGFloat], into count: Int) -> [[Int]] {
        let target = aspects.reduce(0, +) / CGFloat(count)
        var rows = Array(repeating: [Int](), count: count)
        var before: CGFloat = 0
        for (i, aspect) in aspects.enumerated() {
            let row = min(count - 1, max(0, Int((before + aspect / 2) / target)))
            rows[row].append(i)
            before += aspect
        }
        return rows.filter { !$0.isEmpty }
    }

    private static func clamp(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> CGFloat {
        low > high ? low : min(max(value, low), high)
    }
}
