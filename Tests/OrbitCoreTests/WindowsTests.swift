import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// Windows (spec §5.4): matching Accessibility windows to ScreenCaptureKit windows, the Dock preview
/// strip's geometry and hover policy, the running-app order, the thumbnail cache and the settings.
@Suite struct WindowsTests {
    private func pairs(_ ax: [WindowDescriptor], _ capture: [WindowDescriptor]) -> [[Int]] {
        WindowMatcher.match(axWindows: ax, captureWindows: capture).map { [$0.ax, $0.capture] }
    }

    // MARK: Window matching

    /// A known window number wins over title and frame: titles change and windows move between the two reads.
    @Test func matchesByNumber() {
        let ax = [WindowDescriptor(number: 41, title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                  WindowDescriptor(number: 42, title: "Draft", frame: CGRect(x: 100, y: 100, width: 500, height: 400))]
        let capture = [WindowDescriptor(number: 42, title: "Draft — Edited", frame: CGRect(x: 300, y: 300, width: 500, height: 400)),
                       // Same title and frame as Inbox but another number: a different window, never a match.
                       WindowDescriptor(number: 99, title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
                       WindowDescriptor(number: 41, title: "Inbox", frame: CGRect(x: 0, y: 0, width: 800, height: 600))]
        #expect(pairs(ax, capture) == [[0, 2], [1, 0]])
        // A number Accessibility knows that capture doesn't list stays unmatched.
        #expect(pairs([WindowDescriptor(number: 5, title: "Inbox", frame: .zero)],
                      [WindowDescriptor(number: 6, title: "Inbox", frame: .zero)]).isEmpty)
    }

    /// Without a window number: same title (nil counts as empty) and every edge within 2 pt; each capture
    /// window is used once, the closest one first.
    @Test func matchesByTitleAndFrame() {
        let ax = [WindowDescriptor(number: nil, title: "Notes", frame: CGRect(x: 10, y: 20, width: 600, height: 400)),
                  WindowDescriptor(number: nil, title: "Notes", frame: CGRect(x: 700, y: 20, width: 600, height: 400)),
                  WindowDescriptor(number: nil, title: "", frame: CGRect(x: 0, y: 0, width: 300, height: 200))]
        let capture = [WindowDescriptor(number: 7, title: "Notes", frame: CGRect(x: 701.5, y: 18.5, width: 600, height: 401)),
                       WindowDescriptor(number: 8, title: "Notes", frame: CGRect(x: 11, y: 21, width: 599, height: 400)),
                       WindowDescriptor(number: 9, title: nil, frame: CGRect(x: 0, y: 0, width: 300, height: 200))]
        #expect(pairs(ax, capture) == [[0, 1], [1, 0], [2, 2]])
        // Two candidates in tolerance: the nearer frame wins, the other is left for the next window.
        let twins = [WindowDescriptor(number: 1, title: "Notes", frame: CGRect(x: 12, y: 20, width: 600, height: 400)),
                     WindowDescriptor(number: 2, title: "Notes", frame: CGRect(x: 10.5, y: 20, width: 600, height: 400))]
        #expect(pairs([ax[0]], twins) == [[0, 1]])
    }

    @Test func noMatchBeyondTolerance() {
        let ax = [WindowDescriptor(number: nil, title: "Notes", frame: CGRect(x: 10, y: 20, width: 600, height: 400))]
        let capture = [WindowDescriptor(number: 1, title: "Notes", frame: CGRect(x: 12.5, y: 20, width: 600, height: 400)),
                       WindowDescriptor(number: 2, title: "Notes 2", frame: CGRect(x: 10, y: 20, width: 600, height: 400)),
                       WindowDescriptor(number: 3, title: "Notes", frame: CGRect(x: 10, y: 20, width: 600, height: 397))]
        #expect(pairs(ax, capture).isEmpty)
        // Exactly 2 pt off on every edge is still the same window.
        let edge = [WindowDescriptor(number: 4, title: "Notes", frame: CGRect(x: 12, y: 18, width: 600, height: 400))]
        #expect(pairs(ax, edge) == [[0, 0]])
    }

    // MARK: Dock preview layout

    private typealias Layout = DockPreviewLayout
    /// Kevo's main display (6016 × 3384 HiDPI at 2x = 3008 × 1692 pt); the Dock auto-hides, so the visible
    /// frame reaches the bottom edge.
    private let main = CGRect(x: 0, y: 0, width: 3008, height: 1692)

    private func isInside(_ inner: CGRect, _ outer: CGRect) -> Bool {
        inner.minX >= outer.minX - 0.001 && inner.maxX <= outer.maxX + 0.001
            && inner.minY >= outer.minY - 0.001 && inner.maxY <= outer.maxY + 0.001
    }

    @Test func layoutCentresOverIcon() throws {
        let icon = CGRect(x: 1400, y: 4, width: 64, height: 64)
        let layout = try #require(Layout.make(aspectRatios: [1.6, 1.0], iconFrame: icon, edge: .bottom, visibleFrame: main))
        // Full-height thumbnails side by side, 10 pt apart, under a title line, centred over the icon.
        #expect(layout.thumbnailFrames == [CGRect(x: 10, y: 36, width: 224, height: 140),
                                           CGRect(x: 244, y: 36, width: 140, height: 140)])
        #expect(layout.stripFrame.size == CGSize(width: 394, height: 186))
        #expect(layout.stripFrame.midX == icon.midX)
        #expect(layout.stripFrame.minY == icon.maxY + Layout.iconGap)
        #expect(layout.headerFrame == CGRect(x: 10, y: 10, width: 374, height: Layout.headerHeight))
        // One narrow window: the strip keeps room for its title and centres the thumbnail.
        let narrow = try #require(Layout.make(aspectRatios: [0.5], iconFrame: icon, edge: .bottom, visibleFrame: main))
        #expect(narrow.stripFrame.width == Layout.minContentWidth + 2 * Layout.padding)
        #expect(narrow.thumbnailFrames == [CGRect(x: 55, y: 36, width: 70, height: 140)])
        #expect(narrow.stripFrame.midX == icon.midX)
        // Silly aspect ratios fall back or are limited; no windows, no strip.
        let odd = try #require(Layout.make(aspectRatios: [0, .nan, 40], iconFrame: icon, edge: .bottom, visibleFrame: main))
        #expect(odd.thumbnailFrames.map(\.width) == [224, 224, 420])
        #expect(Layout.make(aspectRatios: [], iconFrame: icon, edge: .bottom, visibleFrame: main) == nil)
    }

    @Test func layoutClampsToScreen() throws {
        // An icon at the far right: the strip stops 8 pt from the screen edge.
        let right = try #require(Layout.make(aspectRatios: [1.6, 1.6, 1.6], iconFrame: CGRect(x: 2940, y: 4, width: 64, height: 64),
                                             edge: .bottom, visibleFrame: main))
        #expect(right.stripFrame.maxX == main.maxX - Layout.screenMargin)
        // The display left of the main one has a negative origin.
        let leftScreen = CGRect(x: -2560, y: 252, width: 2560, height: 1440)
        let left = try #require(Layout.make(aspectRatios: [1.6, 1.6, 1.6], iconFrame: CGRect(x: -2556, y: 256, width: 64, height: 64),
                                            edge: .bottom, visibleFrame: leftScreen))
        #expect(left.stripFrame.minX == leftScreen.minX + Layout.screenMargin)
        #expect(left.stripFrame.minY == 256 + 64 + Layout.iconGap)
        // A visible frame that stops above the Dock (Dock not hidden): the strip never dips into the Dock.
        let shown = CGRect(x: 0, y: 80, width: 3008, height: 1612)
        let low = try #require(Layout.make(aspectRatios: [1.6], iconFrame: CGRect(x: 1400, y: 4, width: 64, height: 64),
                                           edge: .bottom, visibleFrame: shown))
        #expect(low.stripFrame.minY == shown.minY + Layout.screenMargin)
        // Thirty windows on a small screen wrap into rows instead of shrinking to slivers, and stay on screen.
        let small = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let many = try #require(Layout.make(aspectRatios: Array(repeating: 1.6, count: 30), iconFrame: CGRect(x: 700, y: 4, width: 48, height: 48),
                                            edge: .bottom, visibleFrame: small))
        #expect(isInside(many.stripFrame, small.insetBy(dx: Layout.screenMargin, dy: Layout.screenMargin)))
        #expect(Set(many.thumbnailFrames.map(\.minY)).count > 1)
        #expect(many.thumbnailFrames.allSatisfy { $0.height > 80 && $0.height <= Layout.maxThumbnailHeight })
        let bounds = CGRect(origin: .zero, size: many.stripFrame.size)
        #expect(many.thumbnailFrames.allSatisfy { isInside($0, bounds.insetBy(dx: Layout.padding, dy: Layout.padding)) })
        // Rows read left to right, top to bottom, and never overlap.
        for (a, b) in zip(many.thumbnailFrames, many.thumbnailFrames.dropFirst()) {
            #expect(b.minY > a.minY || (b.minY == a.minY && b.minX >= a.maxX + Layout.spacing - 0.001))
        }
    }

    @Test func layoutLeftAndRightDock() throws {
        let leftIcon = CGRect(x: 4, y: 800, width: 64, height: 64)
        let left = try #require(Layout.make(aspectRatios: [1.6, 1.0], iconFrame: leftIcon, edge: .left, visibleFrame: main))
        #expect(left.stripFrame.minX == leftIcon.maxX + Layout.iconGap)
        #expect(left.stripFrame.midY == leftIcon.midY)
        #expect(left.thumbnailFrames.allSatisfy { $0.height == Layout.maxThumbnailHeight })

        let rightIcon = CGRect(x: 2940, y: 800, width: 64, height: 64)
        let right = try #require(Layout.make(aspectRatios: [1.6, 1.0], iconFrame: rightIcon, edge: .right, visibleFrame: main))
        #expect(right.stripFrame.maxX == rightIcon.minX - Layout.iconGap)
        #expect(right.stripFrame.midY == rightIcon.midY)

        // An icon near the top of a side Dock: the strip slides down to stay on screen.
        let high = try #require(Layout.make(aspectRatios: [1.6], iconFrame: CGRect(x: 4, y: 1620, width: 64, height: 64),
                                            edge: .left, visibleFrame: main))
        #expect(high.stripFrame.maxY == main.maxY - Layout.screenMargin)
        #expect(high.stripFrame.minX == 4 + 64 + Layout.iconGap)
    }

    /// The pointer can travel from the icon across the gap into the strip without the preview closing.
    @Test func hoverRegionBridgesIconAndStrip() throws {
        let icon = CGRect(x: 1400, y: 4, width: 64, height: 64)
        let layout = try #require(Layout.make(aspectRatios: [1.6, 1.0], iconFrame: icon, edge: .bottom, visibleFrame: main))
        #expect(layout.hoverRegionContains(CGPoint(x: icon.midX, y: icon.midY)))
        #expect(layout.hoverRegionContains(CGPoint(x: icon.midX, y: icon.maxY + Layout.iconGap / 2)))
        #expect(layout.hoverRegionContains(CGPoint(x: layout.stripFrame.minX + 2, y: layout.stripFrame.maxY - 2)))
        #expect(!layout.hoverRegionContains(CGPoint(x: icon.minX - 120, y: icon.midY)))
        #expect(!layout.hoverRegionContains(CGPoint(x: icon.midX, y: layout.stripFrame.maxY + 40)))

        let side = try #require(Layout.make(aspectRatios: [1.6], iconFrame: CGRect(x: 2940, y: 800, width: 64, height: 64),
                                            edge: .right, visibleFrame: main))
        #expect(side.hoverRegionContains(CGPoint(x: 2940 - Layout.iconGap / 2, y: 832)))
        #expect(!side.hoverRegionContains(CGPoint(x: 2940 - Layout.iconGap / 2, y: 832 + 200)))
    }

    /// Thumbnails are captured at the size they are shown, never bigger than the window itself.
    @Test func captureSizeIsSmall() {
        #expect(Layout.capturePixelSize(for: CGSize(width: 1600, height: 1000), scale: 2) == PixelSize(width: 448, height: 280))
        #expect(Layout.capturePixelSize(for: CGSize(width: 100, height: 60), scale: 2) == PixelSize(width: 200, height: 120))
        #expect(Layout.capturePixelSize(for: CGSize(width: 4000, height: 100), scale: 1) == PixelSize(width: 300, height: 100))
        #expect(Layout.capturePixelSize(for: .zero, scale: 2) == PixelSize(width: 2, height: 1))
    }

    @Test func dockEdgeFromPreference() {
        #expect(DockEdge(orientation: nil) == .bottom)
        #expect(DockEdge(orientation: "bottom") == .bottom)
        #expect(DockEdge(orientation: "left") == .left)
        #expect(DockEdge(orientation: "right") == .right)
        #expect(DockEdge(orientation: "sideways") == .bottom)
    }

    /// Accessibility and ScreenCaptureKit measure from the top left of the primary display; AppKit windows
    /// from its bottom left.
    @Test func flipsBetweenTopLeftAndBottomLeft() {
        let primaryHeight: CGFloat = 1692
        #expect(ScreenSpace.flip(CGRect(x: 0, y: 0, width: 100, height: 50), primaryHeight: primaryHeight)
                == CGRect(x: 0, y: 1642, width: 100, height: 50))
        // The display above the main one: negative y in the top-left space.
        #expect(ScreenSpace.flip(CGRect(x: 18, y: 1692, width: 2560, height: 1440), primaryHeight: primaryHeight)
                == CGRect(x: 18, y: -1440, width: 2560, height: 1440))
        let r = CGRect(x: -2560, y: 252, width: 2560, height: 1440)
        #expect(ScreenSpace.flip(ScreenSpace.flip(r, primaryHeight: primaryHeight), primaryHeight: primaryHeight) == r)
    }
}
