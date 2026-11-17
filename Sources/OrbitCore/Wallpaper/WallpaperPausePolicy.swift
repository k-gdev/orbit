import Foundation

/// Everything that decides whether one display's wallpaper plays: what the system reports for that display, and
/// the user's two optional pause preferences (`WallpaperSettings`).
public struct DisplayConditions: Equatable, Sendable {
    /// The wallpaper window can't be seen (a full-screen app or a window covers the whole display).
    public var screenCovered: Bool
    public var screenLocked: Bool
    public var displayAsleep: Bool
    /// The Mac runs on its battery.
    public var onBattery: Bool
    public var lowPowerMode: Bool
    /// Preference: pause on battery power (default off).
    public var pauseOnBattery: Bool
    /// Preference: pause in Low Power Mode (default on).
    public var pauseInLowPower: Bool

    public init(screenCovered: Bool = false, screenLocked: Bool = false, displayAsleep: Bool = false, onBattery: Bool = false,
                lowPowerMode: Bool = false, pauseOnBattery: Bool = false, pauseInLowPower: Bool = true) {
        self.screenCovered = screenCovered
        self.screenLocked = screenLocked
        self.displayAsleep = displayAsleep
        self.onBattery = onBattery
        self.lowPowerMode = lowPowerMode
        self.pauseOnBattery = pauseOnBattery
        self.pauseInLowPower = pauseInLowPower
    }
}

/// Why a wallpaper is paused. `allCases` is the order of precedence when several apply.
public enum PauseReason: String, CaseIterable, Sendable {
    case displayAsleep, screenLocked, screenCovered, lowPowerMode, onBattery

    /// Short text for the panel ("Paused · Screen locked").
    public var label: String {
        switch self {
        case .displayAsleep: "Display asleep"
        case .screenLocked: "Screen locked"
        case .screenCovered: "Hidden behind a window"
        case .lowPowerMode: "Low Power Mode"
        case .onBattery: "On battery"
        }
    }

    fileprivate var rank: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

public enum PlaybackState: Equatable, Sendable {
    case playing
    case paused(PauseReason)

    public var isPlaying: Bool { self == .playing }

    public var pauseReason: PauseReason? {
        guard case .paused(let reason) = self else { return nil }
        return reason
    }

    /// The state of one player shared by several displays showing the same wallpaper: it plays while any of them
    /// plays; otherwise it reports the strongest reason. An empty list plays.
    public static func combined(_ states: [PlaybackState]) -> PlaybackState {
        if states.isEmpty || states.contains(.playing) { return .playing }
        let reason = states.compactMap(\.pauseReason).min { $0.rank < $1.rank }
        return reason.map(PlaybackState.paused) ?? .playing
    }
}

/// When a wallpaper plays: always, except while its display sleeps, the screen is locked, the wallpaper is covered,
/// or (if the user asked) in Low Power Mode or on battery. Nobody can see a paused wallpaper, so pausing costs
/// nothing visible and saves the decoder's work.
public enum WallpaperPausePolicy {
    public static func state(for c: DisplayConditions) -> PlaybackState {
        if c.displayAsleep { return .paused(.displayAsleep) }
        if c.screenLocked { return .paused(.screenLocked) }
        if c.screenCovered { return .paused(.screenCovered) }
        if c.lowPowerMode && c.pauseInLowPower { return .paused(.lowPowerMode) }
        if c.onBattery && c.pauseOnBattery { return .paused(.onBattery) }
        return .playing
    }
}

/// Whether a wallpaper window counts as covered, from what macOS reports about its occlusion.
public enum WallpaperVisibility {
    /// How long a new window may go without macOS ever reporting it visible before it counts as covered. Long enough
    /// for the first occlusion update after ordering front; short enough that a window nobody can see (drawn under
    /// the system wallpaper, say) stops decoding video within seconds.
    public static let grace: TimeInterval = 4

    /// Covered when not visible now and either seen before (it was visible, now something covers it) or never seen
    /// within `grace` seconds of being shown. `secondsSinceShown` nil: not shown yet, so not covered.
    public static func isCovered(visibleNow: Bool, everVisible: Bool, secondsSinceShown: TimeInterval?,
                                 grace: TimeInterval = grace) -> Bool {
        if visibleNow { return false }
        if everVisible { return true }
        guard let secondsSinceShown else { return false }
        return secondsSinceShown >= grace
    }
}

/// Which displays get a wallpaper window, and what to do when that changes (a display unplugged or added, a
/// wallpaper chosen or removed).
public enum WallpaperPlan {
    /// The wallpaper each connected display should show: its assignment, when `isAvailable` says the source can be
    /// played (the video file or downloaded aerial is still there). Unplugged displays keep their assignment but get
    /// no window.
    public static func desired(screens: [DisplayRef], assignments: WallpaperAssignments,
                               isAvailable: (WallpaperSource) -> Bool) -> [String: WallpaperSource] {
        var result: [String: WallpaperSource] = [:]
        for screen in screens {
            guard let source = assignments[screen.key]?.source, isAvailable(source) else { continue }
            result[screen.key] = source
        }
        return result
    }

    /// Display keys whose window must close, open, or switch to another wallpaper. Sorted.
    public struct Changes: Equatable, Sendable {
        public var close: [String]
        public var open: [String]
        public var change: [String]

        public init(close: [String], open: [String], change: [String]) {
            self.close = close
            self.open = open
            self.change = change
        }

        public var isEmpty: Bool { close.isEmpty && open.isEmpty && change.isEmpty }
    }

    /// From the windows that exist (`current`) to `desired`. A source counts as changed only when its `identity`
    /// differs (a refreshed bookmark for the same file is not a change).
    public static func changes(from current: [String: WallpaperSource], to desired: [String: WallpaperSource]) -> Changes {
        Changes(close: current.keys.filter { desired[$0] == nil }.sorted(),
                open: desired.keys.filter { current[$0] == nil }.sorted(),
                change: desired.keys.filter { key in
                    guard let old = current[key], let new = desired[key] else { return false }
                    return old.identity != new.identity
                }.sorted())
    }
}
