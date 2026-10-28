import Foundation

/// "Same on all displays": which wallpaper the connected displays share and which of them must change to show it.
/// Choosing a wallpaper while it is on is handled where the choice is made; this is the catch-up when the setting
/// turns on, at launch and when a display is connected.
public enum WallpaperSync {
    /// The wallpaper every connected display should show, and the displays that don't show it yet.
    public struct Plan: Equatable, Sendable {
        public let source: WallpaperSource
        public let displays: [DisplayRef]

        public init(source: WallpaperSource, displays: [DisplayRef]) {
            self.source = source
            self.displays = displays
        }
    }

    /// The main display's wallpaper; without one, the wallpaper of the first connected display in `screens` order
    /// (the panel's: left to right) that has one; nil when none has. Assignments don't tell "None" from "not set"
    /// (choosing None removes the entry), so a main display without a wallpaper never syncs the others to None.
    public static func source(screens: [DisplayRef], mainKey: String?, assignments: WallpaperAssignments) -> WallpaperSource? {
        if let mainKey, screens.contains(where: { $0.key == mainKey }), let source = assignments[mainKey]?.source {
            return source
        }
        return screens.lazy.compactMap { assignments[$0.key]?.source }.first
    }

    /// The shared wallpaper and the connected displays (in `screens` order) whose wallpaper differs or is missing;
    /// nil when no display has a wallpaper or all of them already match. A video's bookmark doesn't make it
    /// different. Unplugged displays are never part of this.
    public static func plan(screens: [DisplayRef], mainKey: String?, assignments: WallpaperAssignments) -> Plan? {
        guard let source = source(screens: screens, mainKey: mainKey, assignments: assignments) else { return nil }
        let displays = screens.filter { assignments[$0.key]?.source.identity != source.identity }
        return displays.isEmpty ? nil : Plan(source: source, displays: displays)
    }
}

extension WallpaperAssignments {
    /// Brings the connected displays that differ onto the shared wallpaper (see `WallpaperSync.plan`). Returns
    /// whether anything changed.
    @discardableResult
    public mutating func syncDisplays(screens: [DisplayRef], mainKey: String?) -> Bool {
        guard let plan = WallpaperSync.plan(screens: screens, mainKey: mainKey, assignments: self) else { return false }
        for display in plan.displays { assign(plan.source, to: display) }
        return true
    }
}
