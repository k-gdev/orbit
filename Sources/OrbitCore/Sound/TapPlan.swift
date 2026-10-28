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
