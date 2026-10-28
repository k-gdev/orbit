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
public struct TapActivity: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Stop the aggregate's IO and re-arm it for the next audio.
        case pause
    }

    /// How long an app must stay quiet before its aggregate pauses.
    public static let idleDelay: TimeInterval = 5

    /// The aggregate is stopped, waiting for the app's next audio.
    public private(set) var isPaused = false
    /// When the app went quiet; nil while it plays.
    private var quietSince: Date?

    /// A tap built while its app is quiet counts as paused from the start: its first start already waits for
    /// the app's audio (TapAutoStart), so a pause queued behind it would only fire on the first sound.
    public init(now: Date, isPlaying: Bool) {
        quietSince = isPlaying ? nil : now
        isPaused = !isPlaying
    }

    /// Feeds whether the app is playing now (`kAudioProcessPropertyIsRunningOutput`). Returns `.pause` once per
    /// quiet spell, when it has lasted `idleDelay`.
    public mutating func update(isPlaying: Bool, now: Date) -> Action? {
        if isPlaying {
            quietSince = nil
            isPaused = false
            return nil
        }
        if quietSince == nil { quietSince = now }
        guard !isPaused, let since = quietSince, now.timeIntervalSince(since) >= Self.idleDelay else { return nil }
        isPaused = true
        return .pause
    }

    /// When to call `update` again (the end of the current quiet spell's delay), or nil when nothing is pending.
    public func nextCheck() -> Date? {
        guard !isPaused, let since = quietSince else { return nil }
        return since.addingTimeInterval(Self.idleDelay)
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
}
