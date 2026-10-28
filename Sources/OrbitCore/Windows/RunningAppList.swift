import Foundation

/// One running app as the Windows tab lists it (read from `NSRunningApplication` in the app).
public struct RunningAppInfo: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var bundleID: String?
    public var name: String
    /// An ordinary app with a Dock icon (`activationPolicy == .regular`), as opposed to agents and
    /// background helpers such as Orbit itself.
    public var isRegular: Bool
    /// The frontmost app.
    public var isActive: Bool
    public var isHidden: Bool

    public var id: Int32 { pid }

    public init(pid: Int32, bundleID: String?, name: String, isRegular: Bool, isActive: Bool, isHidden: Bool) {
        self.pid = pid
        self.bundleID = bundleID
        self.name = name
        self.isRegular = isRegular
        self.isActive = isActive
        self.isHidden = isHidden
    }
}

/// The order of the Windows tab's app list.
public enum RunningAppList {
    /// Regular apps only; the frontmost first, then by name the way Finder sorts ("App 9" before "App 10",
    /// case ignored), then by pid so the order is stable.
    public static func sort(_ apps: [RunningAppInfo]) -> [RunningAppInfo] {
        apps.filter(\.isRegular).sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.pid < b.pid
            }
        }
    }
}
