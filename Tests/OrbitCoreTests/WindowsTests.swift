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
}
