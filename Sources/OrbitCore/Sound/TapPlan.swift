import Foundation

/// Whether one app needs a process tap, and where its audio then goes.
///
/// A tap (and its private aggregate device) exists only to change something: the app is not at
/// 100 %, or is muted, or plays on a device other than the system output. An app at 100 %, unmuted,
/// on the default output gets no tap at all, so nothing of Orbit sits in its audio path (Review
/// Focus 1). A route to a device that is not connected falls back to the system output, and with no
/// output device at all there is never a tap (it could only mute the app).
public struct TapPlan: Equatable, Sendable {
    /// Whether the app's audio must go through a tap.
    public let needsTap: Bool
    /// The output device the app's audio plays on: its route when that device is available, otherwise
    /// the system output. Nil only when there is no output device.
    public let destinationUID: String?
    /// The linear gain to apply (`VolumeCurve`), 0 when muted.
    public let gain: Float
    public let muted: Bool
    /// The app is sent to a device other than the system output.
    public let isRoutedAway: Bool
    /// The app has a route, but that device is not connected (it plays on the system output meanwhile).
    public let routeUnavailable: Bool

    /// - Parameters:
    ///   - availableOutputUIDs: the connected output devices; nil skips the check.
    public init(preference: AppAudioPreference, defaultOutputUID: String?, availableOutputUIDs: Set<String>? = nil) {
        var route = preference.outputUID
        if let wanted = route, let available = availableOutputUIDs, !available.contains(wanted) {
            route = nil
        }
        routeUnavailable = preference.outputUID != nil && route == nil
        destinationUID = route ?? defaultOutputUID
        isRoutedAway = route != nil && route != defaultOutputUID
        muted = preference.muted
        gain = preference.muted ? 0 : VolumeCurve.gain(forPercent: preference.volume)
        let changesSomething = preference.volume != 100 || preference.muted || isRoutedAway
        needsTap = changesSomething && destinationUID != nil
    }

    /// The gain is past unity, so samples go through `SoftClip`.
    public var isBoosted: Bool { gain > 1 }

    /// The output an app plays on by itself, which "Same as Output" keeps it on: the one connected device
    /// its processes are playing to (an app that chose a device in its own settings), otherwise the system
    /// output. Pass the result as `defaultOutputUID`, so a volume change never moves such an app and a
    /// route to its own device needs no tap.
    public static func followedOutput(appDeviceUIDs: [String], systemOutputUID: String?, availableOutputUIDs: Set<String>) -> String? {
        let own = Set(appDeviceUIDs.filter(availableOutputUIDs.contains))
        if own.count == 1, Set(appDeviceUIDs).count == 1, let device = own.first { return device }
        return systemOutputUID
    }
}

/// When a tap's aggregate device should stop doing IO because its app went quiet.
///
/// A tap stays built while its app is a Core Audio client, but running the aggregate's IO the whole time
/// would wake the CPU constantly, keep the output streaming (a Bluetooth headset's battery) and keep
/// coreaudiod's idle-sleep assertion up. So once the app has been quiet for `idleDelay` the aggregate is
/// stopped and re-armed with `kAudioAggregateDeviceTapAutoStartKey`, which restarts it with the app's next
/// audio. Nothing is rebuilt; with `.mutedWhenTapped` the app is never muted while the IO is stopped.
///
/// Times are on the monotonic `ContinuousClock`, so a change of the wall clock can't stretch a quiet spell (and
/// keep an aggregate streaming silence meanwhile).
public struct TapActivity: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Stop the aggregate's IO and re-arm it for the next audio.
        case pause
    }

    /// How long an app must stay quiet before its aggregate pauses.
    public static let idleDelay: Duration = .seconds(5)

    /// The aggregate is stopped, waiting for the app's next audio.
    public private(set) var isPaused = false
    /// When the app went quiet; nil while it plays.
    private var quietSince: ContinuousClock.Instant?

    /// A tap built while its app is quiet counts as paused from the start: its first start already waits for
    /// the app's audio (TapAutoStart), so a pause queued behind it would only fire on the first sound.
    public init(now: ContinuousClock.Instant, isPlaying: Bool) {
        quietSince = isPlaying ? nil : now
        isPaused = !isPlaying
    }

    /// Feeds whether the app is playing now (`kAudioProcessPropertyIsRunningOutput`). Returns `.pause` once per
    /// quiet spell, when it has lasted `idleDelay`.
    public mutating func update(isPlaying: Bool, now: ContinuousClock.Instant) -> Action? {
        if isPlaying {
            quietSince = nil
            isPaused = false
            return nil
        }
        if quietSince == nil { quietSince = now }
        guard !isPaused, let since = quietSince, now - since >= Self.idleDelay else { return nil }
        isPaused = true
        return .pause
    }

    /// When to call `update` again (the end of the current quiet spell's delay), or nil when nothing is pending.
    public func nextCheck() -> ContinuousClock.Instant? {
        guard !isPaused, let since = quietSince else { return nil }
        return since + Self.idleDelay
    }
}

/// The idle pause for every live tap, current or kept predecessor (`TapRoster`). Each tap has its own `TapActivity`, so
/// a replaced tap kept until its successor starts is paused too once its app has been quiet for `idleDelay`, instead of
/// streaming silence until the app's next sound (which may be hours away).
public struct TapActivityBook<ID: Hashable & Sendable>: Equatable, Sendable {
    /// One live tap as the engine sees it now.
    public struct Tap: Equatable, Sendable {
        public var id: ID
        /// Its app is playing (`kAudioProcessPropertyIsRunningOutput`).
        public var isPlaying: Bool
        /// Its first start has returned. Only then is it paused: before that, its own start already waits for audio.
        public var hasStarted: Bool

        public init(id: ID, isPlaying: Bool, hasStarted: Bool) {
            self.id = id
            self.isPlaying = isPlaying
            self.hasStarted = hasStarted
        }
    }

    private var activity: [ID: TapActivity] = [:]

    public init() {}

    public func isTracking(_ id: ID) -> Bool { activity[id] != nil }

    /// A tap was just built (`TapActivity(now:isPlaying:)`).
    public mutating func track(_ id: ID, isPlaying: Bool, now: ContinuousClock.Instant) {
        activity[id] = TapActivity(now: now, isPlaying: isPlaying)
    }

    /// Feeds every live tap. Returns the taps to pause now (each once per quiet spell, and only once started) and when
    /// to look again (the earliest pending quiet spell's end). Taps no longer listed are forgotten.
    public mutating func update(_ taps: [Tap], now: ContinuousClock.Instant) -> (pause: [ID], nextCheck: ContinuousClock.Instant?) {
        var pause: [ID] = []
        var next: ContinuousClock.Instant?
        var kept: [ID: TapActivity] = [:]
        for tap in taps {
            var state = activity[tap.id] ?? TapActivity(now: now, isPlaying: tap.isPlaying)
            if state.update(isPlaying: tap.isPlaying, now: now) == .pause, tap.hasStarted { pause.append(tap.id) }
            if let check = state.nextCheck() { next = min(next ?? check, check) }
            kept[tap.id] = state
        }
        activity = kept
        return (pause, next)
    }
}

/// Who tears a tap down, and when, so releasing it never waits for a start that may block.
///
/// With `kAudioAggregateDeviceTapAutoStartKey`, `AudioDeviceStart` may only return with the app's next audio.
/// A tap's HAL work runs on its own serial queue, so a release queued there could sit behind such a start
/// indefinitely. Instead: while the queue is inside a waiting start, a release tears down from outside the
/// queue at once; when the start returns afterwards, the queue sees the tap is gone and stops. Exactly one
/// party performs the teardown (`claimTeardown`). The app keeps this behind a lock.
public struct TapLifecycle: Equatable, Sendable {
    public enum Teardown: Equatable, Sendable {
        /// The queue is free (or will be soon): tear down on it.
        case onQueue
        /// The queue is inside a start that may block: tear down from outside it now.
        case fromOutside
        /// Already torn down (a creation failure, or a second release).
        case alreadyDone
    }

    public private(set) var isWaitingForAudio = false
    public private(set) var isInvalidated = false
    public private(set) var isTornDown = false

    public init() {}

    /// The queue is about to call a start that may block until the app's next sound. False when the tap was
    /// released already: don't start.
    public mutating func beginWaitingStart() -> Bool {
        guard !isInvalidated, !isTornDown else { return false }
        isWaitingForAudio = true
        return true
    }

    /// That start returned. True when the tap is still alive (carry on); false when it was released meanwhile
    /// (stop there and report nothing: the teardown has happened or is happening elsewhere).
    public mutating func endWaitingStart() -> Bool {
        isWaitingForAudio = false
        return !isInvalidated && !isTornDown
    }

    /// The tap is released. Where its teardown must run.
    public mutating func invalidate() -> Teardown {
        guard !isTornDown else { return .alreadyDone }
        isInvalidated = true
        return isWaitingForAudio ? .fromOutside : .onQueue
    }

    /// True exactly once: whoever gets it performs the HAL teardown.
    public mutating func claimTeardown() -> Bool {
        guard !isTornDown else { return false }
        isTornDown = true
        return true
    }
}

/// Which taps each app has: its current one, and the ones it replaced that are still alive.
///
/// A replacement tap is started before the one it replaces is released (so the app is never heard
/// unattenuated in between); the old one "retires" until its successor has started. The rules here make sure
/// no retired tap outlives that: a start releases every tap built before it, a failure of the current tap
/// releases it and every older one (a failed retiring tap takes only itself), and releasing an app releases its
/// current tap and all its predecessors (a tap released before it got going reports nothing, so its
/// predecessors can't wait for its report). Only a tap that has started can be playing the app, so a new tap
/// keeps just the newest such predecessor and releases the others at once: a quiet app rebuilt again and again
/// (an output flapping, its processes churning) never piles up replaced taps. The one exception: while the app is
/// playing, the newest replaced tap that hasn't been noted as started is kept too, since its start may just have
/// returned (with its report still on the way) and it may be the tap playing the app. Pure bookkeeping; the
/// engine invalidates what the calls return.
public struct TapRoster<ID: Hashable & Sendable>: Equatable, Sendable {
    /// Each app's current tap.
    public private(set) var currentByApp: [String: ID] = [:]
    /// Each app's replaced taps still alive, oldest first. After an install, at most two: the newest one that has
    /// started, and (only if the app was playing then) the newest one not noted as started.
    private var retiringByApp: [String: [ID]] = [:]
    /// The live taps that have started (their IO has run, so they may be playing, or paused and re-armed).
    private var startedTaps: Set<ID> = []

    public init() {}

    public func current(for app: String) -> ID? { currentByApp[app] }
    public func retiring(for app: String) -> [ID] { retiringByApp[app] ?? [] }
    /// Every tap still alive.
    public var all: [ID] { Array(currentByApp.values) + retiringByApp.values.flatMap { $0 } }
    public var isEmpty: Bool { currentByApp.isEmpty && retiringByApp.isEmpty }

    /// `tap` becomes the app's current tap. Of the taps it replaces, the newest one that has started stays (it may be
    /// playing the app at its setting) until `tap` starts. The others haven't been noted as started: normally their
    /// start still waits for the app's audio, so they aren't playing and releasing them is silent. Kept, each would
    /// hold a process tap, an aggregate and a thread blocked in its start, and they would all start at the app's first
    /// sound at stale gains and devices. But if the newest of them belongs to an app playing right now (`isPlaying`,
    /// asked about that one tap only: its processes' `IsRunningOutput`), its start may have just returned with the
    /// report still on its way, so it may be playing the app: it stays too. Returns those to release.
    @discardableResult
    public mutating func install(_ tap: ID, for app: String, isPlaying: (ID) -> Bool = { _ in false }) -> [ID] {
        var replaced = retiringByApp.removeValue(forKey: app) ?? []
        if let old = currentByApp[app] { replaced.append(old) }
        currentByApp[app] = tap
        // A start releases every older tap, so taps not noted as started are all newer than the newest that started.
        let started = replaced.last(where: startedTaps.contains)
        let justStarting = replaced.last.flatMap { !startedTaps.contains($0) && isPlaying($0) ? $0 : nil }
        let kept = [started, justStarting].compactMap { $0 }
        if !kept.isEmpty { retiringByApp[app] = kept }
        return forget(replaced.filter { !kept.contains($0) })
    }

    /// `tap` has started: every tap of the app built before it is done. Returns those to release.
    public mutating func started(_ tap: ID, for app: String) -> [ID] {
        if currentByApp[app] == tap {
            startedTaps.insert(tap)
            return removeRetiring(app, upTo: nil)
        }
        guard let index = retiringByApp[app]?.firstIndex(of: tap) else { return [] }
        startedTaps.insert(tap)
        return removeRetiring(app, upTo: index)
    }

    /// `tap` failed (or stopped working). Returns those to release:
    /// - the current tap: it and every tap of the app built before it (the app plays as usual meanwhile, and no
    ///   successor is left whose start would release them);
    /// - a retiring tap: only itself. An older one may still be playing the app at its setting, and goes when the
    ///   current tap starts or fails, or the app is released.
    public mutating func failed(_ tap: ID, for app: String) -> [ID] {
        if currentByApp[app] == tap {
            currentByApp[app] = nil
            return removeRetiring(app, upTo: nil) + forget([tap])
        }
        guard var list = retiringByApp[app], let index = list.firstIndex(of: tap) else { return [] }
        list.remove(at: index)
        retiringByApp[app] = list.isEmpty ? nil : list
        return forget([tap])
    }

    /// The app needs no tap any more: its current tap and every predecessor. Returns those to release.
    public mutating func release(_ app: String) -> [ID] {
        var released: [ID] = []
        if let current = currentByApp.removeValue(forKey: app) { released.append(current) }
        released += retiringByApp.removeValue(forKey: app) ?? []
        return forget(released)
    }

    /// Everything (the feature is turned off, Orbit quits).
    public mutating func releaseAll() -> [ID] {
        let everything = all
        currentByApp = [:]
        retiringByApp = [:]
        startedTaps = []
        return everything
    }

    /// Removes and returns the app's retiring taps before index `end` (all of them when nil).
    private mutating func removeRetiring(_ app: String, upTo end: Int?) -> [ID] {
        guard var list = retiringByApp[app] else { return [] }
        let count = min(end ?? list.count, list.count)
        let removed = Array(list.prefix(count))
        list.removeFirst(count)
        retiringByApp[app] = list.isEmpty ? nil : list
        return forget(removed)
    }

    /// Released taps are no longer tracked as started; returns them.
    private mutating func forget(_ released: [ID]) -> [ID] {
        released.forEach { startedTaps.remove($0) }
        return released
    }
}

/// The output devices each app last played on. Core Audio reports no devices for a process that is idle,
/// so without this "Same as Output" would flip an idle app to the system output and back on every sound.
/// An app's devices are kept while it has audio processes and forgotten when they are gone.
public struct AppOutputMemory: Equatable, Sendable {
    private var remembered: [String: [String]] = [:]

    public init() {}

    /// Records what an app's processes report right now and returns the devices to plan with: what they
    /// report while playing somewhere, the last such devices while the app is idle, nothing once its
    /// processes are gone (the memory is dropped then).
    public mutating func observe(app: String, deviceUIDs: [String], hasProcesses: Bool) -> [String] {
        guard hasProcesses else {
            remembered[app] = nil
            return []
        }
        if !deviceUIDs.isEmpty { remembered[app] = deviceUIDs }
        return remembered[app] ?? []
    }

    /// The remembered devices of an app (empty when none).
    public func devices(for app: String) -> [String] {
        remembered[app] ?? []
    }

    /// Forgets every app not in `apps` (apps whose processes went away).
    public mutating func forgetApps(notIn apps: Set<String>) {
        remembered = remembered.filter { apps.contains($0.key) }
    }

    /// The system output changed from `old`. Apps remembered on exactly that device were following the system
    /// output (macOS moves them along), so their memory goes and an idle one follows the switch; apps on a
    /// device of their own keep it.
    public mutating func systemOutputChanged(from old: String?) {
        guard let old else { return }
        remembered = remembered.filter { !$0.value.allSatisfy { $0 == old } }
    }
}
