import Foundation

/// A mounted volume as `FileManager` describes it (`URLResourceKey.volumeIs…`). `isInternal` is nil when
/// macOS doesn't say (disk images and network shares often don't).
public struct VolumeInfo: Equatable, Hashable, Sendable, Identifiable {
    public var path: String
    public var name: String
    public var isInternal: Bool?
    public var isRemovable: Bool
    public var isEjectable: Bool
    public var isLocal: Bool
    public var isRootFileSystem: Bool
    public var isBrowsable: Bool

    public var id: String { path }

    public init(path: String, name: String, isInternal: Bool?, isRemovable: Bool, isEjectable: Bool, isLocal: Bool,
                isRootFileSystem: Bool, isBrowsable: Bool) {
        self.path = path
        self.name = name
        self.isInternal = isInternal
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isLocal = isLocal
        self.isRootFileSystem = isRootFileSystem
        self.isBrowsable = isBrowsable
    }
}

/// Which volumes "Eject Drives" may eject: external or removable drives and mounted disk images that
/// Finder shows under /Volumes. Never the boot volume, system volumes, internal partitions, network
/// shares, or hidden images such as the Simulator runtimes under /Library/Developer.
public enum EjectableVolumeFilter {
    public static func ejectable(_ volumes: [VolumeInfo]) -> [VolumeInfo] {
        volumes.filter { v in
            guard v.path.hasPrefix("/Volumes/"), v.isLocal, v.isBrowsable, !v.isRootFileSystem else { return false }
            return v.isEjectable || v.isRemovable || v.isInternal == false
        }
    }

    /// The in-panel question: "Eject “Backup SSD”?" or "Eject 2 drives?".
    public static func confirmation(_ volumes: [VolumeInfo]) -> String {
        volumes.count == 1 ? "Eject “\(volumes[0].name)”?" : "Eject \(volumes.count) drives?"
    }

    /// The toast after ejecting: "Ejected 2 drives", "Couldn’t eject “Backup SSD”", or both.
    public static func summary(ejected: [String], failed: [String]) -> String {
        func drives(_ names: [String]) -> String { names.count == 1 ? "“\(names[0])”" : "\(names.count) drives" }
        switch (ejected.isEmpty, failed.isEmpty) {
        case (true, true): return "No drives to eject"
        case (false, true): return "Ejected \(drives(ejected))"
        case (true, false): return "Couldn’t eject \(drives(failed))"
        case (false, false): return "Ejected \(drives(ejected)); couldn’t eject \(drives(failed))"
        }
    }
}
