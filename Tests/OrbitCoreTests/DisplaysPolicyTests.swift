import Foundation
import Testing
@testable import OrbitCore

/// The "Keep this resolution?" countdown (M2) and the other-app hint (M6).
@Suite struct ResolutionConfirmationTests {
    private let previous = RawDisplayMode(id: 82, width: 3008, height: 1692, pixelWidth: 6016, pixelHeight: 3384, refreshRate: 60)
    private let proposed = RawDisplayMode(id: 75, width: 2560, height: 1440, pixelWidth: 5120, pixelHeight: 2880, refreshRate: 60)

    @Test func countsDownFifteenSecondsThenExpires() {
        let start = Date(timeIntervalSinceReferenceDate: 1000)
        let confirmation = ResolutionConfirmation(displayID: 2, displayTitle: "P27u-20 · Left", previous: previous, proposed: proposed,
                                                  proposedLabel: "2560 × 1440 HiDPI", startedAt: start)
        #expect(ResolutionConfirmation.duration == 15)
        #expect(confirmation.deadline == start.addingTimeInterval(15))
        #expect(confirmation.secondsLeft(at: start) == 15)
        #expect(confirmation.secondsLeft(at: start.addingTimeInterval(0.2)) == 15)      // rounded up
        #expect(confirmation.secondsLeft(at: start.addingTimeInterval(14.1)) == 1)
        #expect(confirmation.secondsLeft(at: start.addingTimeInterval(20)) == 0)
        #expect(!confirmation.isExpired(at: start.addingTimeInterval(14.9)))
        #expect(confirmation.isExpired(at: start.addingTimeInterval(15)))
        #expect(confirmation.countdown(at: start.addingTimeInterval(3)) == "Reverting in 12 s")
        #expect(confirmation.countdown(at: start.addingTimeInterval(15)) == "Reverting…")
    }

    @Test func hintNamesTheOtherDisplayApps() {
        #expect(DisplayConflicts.hint(runningBundleIDs: ["com.apple.finder"]) == nil)
        #expect(DisplayConflicts.hint(runningBundleIDs: []) == nil)
        #expect(DisplayConflicts.hint(runningBundleIDs: ["com.apple.finder", "pro.betterdisplay.BetterDisplay"])
                == "BetterDisplay is also running and controls these monitors. Quit it so the two don't undo each other.")
        #expect(DisplayConflicts.hint(runningBundleIDs: ["fyi.lunar.Lunar", "pro.betterdisplay.BetterDisplay", "fyi.lunar.Lunar"])
                == "BetterDisplay and Lunar are also running and control these monitors. Quit them so they don't undo Orbit's changes.")
    }
}

/// The gamma table Orbit keeps as a display's original (M4).
@Suite struct GammaRampTests {
    @Test func trustsANormalTable() {
        let normal = GammaRamp(red: [0, 0.5, 1], green: [0, 0.48, 0.99], blue: [0, 0.5, 1])
        #expect(normal.peak == 1)
        let (ramp, suspect) = normal.trustedOriginal()
        #expect(ramp == normal)
        #expect(!suspect)
    }

    @Test func liftsAnAlreadyDimmedTable() {
        // Someone dimmed it to half: the original is taken as twice that, channels kept in balance.
        let dimmed = GammaRamp(red: [0, 0.25, 0.5], green: [0, 0.2, 0.4], blue: [0, 0.25, 0.5])
        #expect(dimmed.peak == 0.5)
        let (ramp, suspect) = dimmed.trustedOriginal()
        #expect(suspect)
        #expect(ramp == GammaRamp(red: [0, 0.5, 1], green: [0, 0.4, 0.8], blue: [0, 0.5, 1]))
        // Nearly black: a straight ramp of the same length.
        let black = GammaRamp(red: [0, 0.01, 0.02], green: [0, 0, 0.01], blue: [0, 0.01, 0.02])
        let (fallback, wasSuspect) = black.trustedOriginal()
        #expect(wasSuspect)
        #expect(fallback == GammaRamp.identity(count: 3))
        #expect(GammaRamp.identity(count: 3) == GammaRamp(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1]))
        #expect(GammaRamp.identity(count: 1).red == [1])
    }

    @Test func scalesEveryChannel() {
        let ramp = GammaRamp.identity(count: 3).scaled(by: 0.5)
        #expect(ramp == GammaRamp(red: [0, 0.25, 0.5], green: [0, 0.25, 0.5], blue: [0, 0.25, 0.5]))
        #expect(GammaRamp.identity(count: 3).scaled(by: 1) == GammaRamp.identity(count: 3))
    }
}

/// Learning a boost range needs two validated readings in a row above the reported maximum (M3).
@Suite struct BoostLearnerTests {
    @Test func learnsOnlyAfterTwoReadingsInARow() {
        var learner = BoostLearner()
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == nil)
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == 150)
        // The lower of the two is learned.
        var other = BoostLearner()
        #expect(other.observe(VCPValue(current: 140, maximum: 100), for: "tv") == nil)
        #expect(other.observe(VCPValue(current: 130, maximum: 100), for: "tv") == 130)
        // Keys are independent.
        var mixed = BoostLearner()
        #expect(mixed.observe(VCPValue(current: 150, maximum: 100), for: "left") == nil)
        #expect(mixed.observe(VCPValue(current: 150, maximum: 100), for: "right") == nil)
        #expect(mixed.observe(VCPValue(current: 150, maximum: 100), for: "left") == 150)
    }

    @Test func aNormalReadingOrForgetBreaksTheRun() {
        var learner = BoostLearner()
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == nil)
        #expect(learner.observe(VCPValue(current: 80, maximum: 100), for: "tv") == nil)   // within range
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == nil)   // starts again
        learner.forget("tv")
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == nil)
        #expect(learner.observe(VCPValue(current: 150, maximum: 100), for: "tv") == 150)
        // Readings at or below the maximum never teach anything.
        var plain = BoostLearner()
        #expect(plain.observe(VCPValue(current: 100, maximum: 100), for: "aoc") == nil)
        #expect(plain.observe(VCPValue(current: 100, maximum: 100), for: "aoc") == nil)
    }

    @Test func settingsForgetTheLearnedRange() {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let settings = DisplaySettings(defaults: defaults)
        settings.learn(maximum: 150, reported: 100, for: "tv")
        settings.learn(maximum: 150, reported: 100, for: "aoc")
        settings.forgetLearnedMaximum(for: "tv")
        #expect(settings.learnedMaximums == ["aoc": 150])
        #expect(DisplaySettings(defaults: defaults).learnedMaximums == ["aoc": 150])
        settings.forgetLearnedMaximum(for: "missing")   // harmless
        #expect(settings.learnedMaximums == ["aoc": 150])
    }
}

/// The tile-control decisions for displays that answer DDC, miss replies, sleep or never answer
/// (Review Focus #2).
@Suite struct DisplayControlPolicyTests {
    private let reading = VCPValue(current: 150, maximum: 100)

    @Test func startDecisions() {
        let new = DDCProbeState()
        let answered = DDCProbeState(hasAnswered: true)
        // A display never asked starts as "Checking DDC…" and is asked.
        #expect(DisplayControlPolicy.start(state: new, ddcSupported: true, asleep: false, gammaFallback: true) == (.probing, true))
        // One that answered shows DDC (last value) while it's asked again.
        #expect(DisplayControlPolicy.start(state: answered, ddcSupported: true, asleep: false, gammaFallback: true) == (.ddc, true))
        // No DDC on this Mac (Intel): straight to the fallback, never asked.
        #expect(DisplayControlPolicy.start(state: new, ddcSupported: false, asleep: false, gammaFallback: true) == (.software, false))
        #expect(DisplayControlPolicy.start(state: new, ddcSupported: false, asleep: false, gammaFallback: false) == (.unavailable, false))
        // Asleep: not asked; keeps DDC if it answered before.
        #expect(DisplayControlPolicy.start(state: new, ddcSupported: true, asleep: true, gammaFallback: true) == (.software, false))
        #expect(DisplayControlPolicy.start(state: answered, ddcSupported: true, asleep: true, gammaFallback: true) == (.ddc, false))
        // Gave up after three misses: not asked again until wake / a display change.
        let gaveUp = DDCProbeState(hasAnswered: false, misses: DisplayControlPolicy.maxMisses)
        #expect(DisplayControlPolicy.start(state: gaveUp, ddcSupported: true, asleep: false, gammaFallback: true) == (.software, false))
        var answeredGaveUp = gaveUp
        answeredGaveUp.hasAnswered = true
        #expect(DisplayControlPolicy.start(state: answeredGaveUp, ddcSupported: true, asleep: false, gammaFallback: true) == (.software, false))
    }

    @Test func successBecomesDDCAndClearsSoftwareDim() {
        let outcome = DisplayControlPolicy.outcome(of: reading, state: DDCProbeState(misses: 2), gammaFallback: true)
        #expect(outcome == DisplayControlPolicy.Outcome(control: .ddc, state: DDCProbeState(hasAnswered: true, misses: 0),
                                                        adoptsReading: true, clearsSoftwareDim: true, retryAfter: nil))
    }

    @Test func missedReplyKeepsDDCForADisplayThatAnswered() {
        let first = DisplayControlPolicy.outcome(of: nil, state: DDCProbeState(hasAnswered: true), gammaFallback: true)
        #expect(first == DisplayControlPolicy.Outcome(control: .ddc, state: DDCProbeState(hasAnswered: true, misses: 1),
                                                      adoptsReading: false, clearsSoftwareDim: false, retryAfter: 1))
        let second = DisplayControlPolicy.outcome(of: nil, state: first.state, gammaFallback: true)
        #expect(second.control == .ddc)
        #expect(second.retryAfter == 3)
        // Only after the third miss in a row does it fall back.
        let third = DisplayControlPolicy.outcome(of: nil, state: second.state, gammaFallback: true)
        #expect(third == DisplayControlPolicy.Outcome(control: .software, state: DDCProbeState(hasAnswered: true, misses: 3),
                                                      adoptsReading: false, clearsSoftwareDim: false, retryAfter: nil))
        // A reply in between resets the count.
        let back = DisplayControlPolicy.outcome(of: reading, state: second.state, gammaFallback: true)
        #expect(back.state == DDCProbeState(hasAnswered: true, misses: 0))
    }

    @Test func silentDisplayRetriesWithBackoffThenFallsBack() {
        var state = DDCProbeState()
        var outcomes: [DisplayControlPolicy.Outcome] = []
        for _ in 0..<3 {
            let outcome = DisplayControlPolicy.outcome(of: nil, state: state, gammaFallback: true)
            outcomes.append(outcome)
            state = outcome.state
        }
        #expect(outcomes.map(\.control) == [.probing, .probing, .software])
        #expect(outcomes.map(\.retryAfter) == [1, 3, nil])
        #expect(outcomes.allSatisfy { !$0.adoptsReading && !$0.clearsSoftwareDim })
        #expect(state == DDCProbeState(hasAnswered: false, misses: 3))
        // With software dimming turned off it ends with no brightness control.
        let off = DisplayControlPolicy.outcome(of: nil, state: DDCProbeState(misses: 2), gammaFallback: false)
        #expect(off.control == .unavailable)
    }

    @Test func softwareDimIsOnlyRememberedForDisplaysThatNeverAnswered() {
        #expect(DisplayControlPolicy.persistsSoftwareDim(DDCProbeState()))
        #expect(DisplayControlPolicy.persistsSoftwareDim(DDCProbeState(misses: 3)))
        #expect(!DisplayControlPolicy.persistsSoftwareDim(DDCProbeState(hasAnswered: true)))
        #expect(!DisplayControlPolicy.persistsSoftwareDim(DDCProbeState(hasAnswered: true, misses: 3)))
    }

    @Test func wakeAsksDisplaysThatGaveUpAgain() {
        #expect(DisplayControlPolicy.afterWake(DDCProbeState(misses: 3)) == DDCProbeState())
        #expect(DisplayControlPolicy.afterWake(DDCProbeState(hasAnswered: true, misses: 2)) == DDCProbeState(hasAnswered: true))
        let woke = DisplayControlPolicy.afterWake(DDCProbeState(misses: 3))
        #expect(DisplayControlPolicy.start(state: woke, ddcSupported: true, asleep: false, gammaFallback: true) == (.probing, true))
    }
}
