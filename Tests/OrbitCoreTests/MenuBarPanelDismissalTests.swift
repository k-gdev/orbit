import Foundation
import Testing
@testable import OrbitCore

/// When the menu bar panel closes because another app became active (⌘-Tab, a Dock click).
@Suite struct MenuBarPanelDismissalTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let orbit: Int32 = 500

    @Test func anotherAppBecomingActiveClosesThePanel() {
        #expect(MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: nil, now: now))
        // A click in the panel a while ago doesn't count.
        #expect(MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: now.addingTimeInterval(-5), now: now))
        // An activation notification without its app still closes it.
        #expect(MenuBarPanelDismissal.closesOnActivation(of: nil, ownPID: orbit, lastPanelClick: nil, now: now))
    }

    @Test func orbitItselfBecomingActiveKeepsIt() {
        // An open panel from the panel's own Settings… or Open Files… activates Orbit.
        #expect(!MenuBarPanelDismissal.closesOnActivation(of: orbit, ownPID: orbit, lastPanelClick: nil, now: now))
    }

    /// Hiding or quitting the frontmost app from the Windows tab makes macOS activate the next app: that
    /// follows a click in the panel, and the panel stays for the next action.
    @Test func anActivationRightAfterAClickInThePanelKeepsIt() {
        #expect(MenuBarPanelDismissal.clickGrace == 1)
        #expect(!MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: now.addingTimeInterval(-0.3), now: now))
        #expect(!MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: now.addingTimeInterval(-1), now: now))
        #expect(MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: now.addingTimeInterval(-1.01), now: now))
        // A click "in the future" (the clock moved back) is no reason to stay.
        #expect(MenuBarPanelDismissal.closesOnActivation(of: 812, ownPID: orbit, lastPanelClick: now.addingTimeInterval(30), now: now))
    }
}
