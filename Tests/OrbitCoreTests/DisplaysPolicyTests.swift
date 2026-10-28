import Foundation
import Testing
@testable import OrbitCore

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
