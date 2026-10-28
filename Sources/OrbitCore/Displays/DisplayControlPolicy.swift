import Foundation

/// What Orbit knows about one display's DDC during this run.
public struct DDCProbeState: Equatable, Sendable {
    /// It has given a valid DDC reply (this run, or remembered from an earlier one).
    public var hasAnswered: Bool
    /// Probes in a row without a valid reply.
    public var misses: Int

    public init(hasAnswered: Bool = false, misses: Int = 0) {
        self.hasAnswered = hasAnswered
        self.misses = misses
    }
}

/// How a non-native display's tile is driven, decided from DDC probes (Review Focus #2: a display that
/// doesn't answer, sleeps or misses a reply). Pure; `DisplaysModel` applies the outcomes.
///
/// - A valid reply makes the display DDC and ends any software dimming of it.
/// - A display that never answered is asked `maxMisses` times, `retryDelays` apart (re-walking the
///   IORegistry first), before it falls back to software dimming (or no control with that turned off).
/// - A display that has answered keeps DDC and its last value through missed replies, is re-scanned and
///   asked again, and only falls back after `maxMisses` misses in a row.
/// - After wake or a display change, displays that gave up are asked again.
/// - A software-dimming level is only remembered for displays that have never answered DDC.
public enum DisplayControlPolicy {
    /// Probes without a valid reply before a display stops being asked (until wake or a display change).
    public static let maxMisses = 3
    /// The wait before the second and third probe.
    public static let retryDelays: [TimeInterval] = [1, 3]

    /// What happens after one probe.
    public struct Outcome: Equatable, Sendable {
        public var control: BrightnessControl
        public var state: DDCProbeState
        /// Show the reading's current value in the pill.
        public var adoptsReading: Bool
        /// Stop software-dimming the display and forget its saved level.
        public var clearsSoftwareDim: Bool
        /// Probe again after this long, re-walking the IORegistry first; nil = no retry.
        public var retryAfter: TimeInterval?

        public init(control: BrightnessControl, state: DDCProbeState, adoptsReading: Bool, clearsSoftwareDim: Bool,
                    retryAfter: TimeInterval?) {
            self.control = control
            self.state = state
            self.adoptsReading = adoptsReading
            self.clearsSoftwareDim = clearsSoftwareDim
            self.retryAfter = retryAfter
        }
    }

    /// Before probing (the tab appeared): how the tile starts, and whether to ask the display over DDC.
    public static func start(state: DDCProbeState, ddcSupported: Bool, asleep: Bool, gammaFallback: Bool)
        -> (control: BrightnessControl, probe: Bool) {
        guard ddcSupported, state.misses < maxMisses else { return (fallback(gammaFallback), false) }
        if asleep { return (state.hasAnswered ? .ddc : fallback(gammaFallback), false) }
        return (state.hasAnswered ? .ddc : .probing, true)
    }

    /// The tile after one probe (`reading` nil = no valid reply).
    public static func outcome(of reading: VCPValue?, state: DDCProbeState, gammaFallback: Bool) -> Outcome {
        if reading != nil {
            return Outcome(control: .ddc, state: DDCProbeState(hasAnswered: true, misses: 0),
                           adoptsReading: true, clearsSoftwareDim: true, retryAfter: nil)
        }
        let next = DDCProbeState(hasAnswered: state.hasAnswered, misses: state.misses + 1)
        guard next.misses < maxMisses else {
            return Outcome(control: fallback(gammaFallback), state: next, adoptsReading: false, clearsSoftwareDim: false, retryAfter: nil)
        }
        let delay = retryDelays[min(next.misses - 1, retryDelays.count - 1)]
        return Outcome(control: state.hasAnswered ? .ddc : .probing, state: next, adoptsReading: false, clearsSoftwareDim: false,
                       retryAfter: delay)
    }

    /// Whether a software-dimming level may be saved for the display: only if it has never answered DDC
    /// (a DDC monitor that misses replies for a while is dimmed in software for this run only).
    public static func persistsSoftwareDim(_ state: DDCProbeState) -> Bool { !state.hasAnswered }

    /// After wake or a display change: displays that gave up are asked again.
    public static func afterWake(_ state: DDCProbeState) -> DDCProbeState { DDCProbeState(hasAnswered: state.hasAnswered, misses: 0) }

    static func fallback(_ gammaFallback: Bool) -> BrightnessControl { gammaFallback ? .software : .unavailable }
}
