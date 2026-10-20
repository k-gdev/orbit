import Foundation

/// Whether macOS has granted Orbit Full Disk Access, which lets it read Desktop, Documents, Downloads and
/// other protected folders without a separate prompt for each.
public enum FullDiskAccess {
    /// Opens System Settings at Privacy & Security → Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!

    /// Files that only an app with Full Disk Access can read. macOS has no API that reports this grant,
    /// so we try the read instead: the TCC database exists on every Mac, and Safari's bookmarks cover a
    /// Mac where the first is unavailable. Either being readable means the grant is in place.
    ///
    /// `isReadableFile(atPath:)` is a real open-for-read check against the sandbox/TCC layer, not a
    /// permission-bit lookup, so it reports false for these paths when access has not been granted.
    static var probePaths: [String] {
        ["/Library/Application Support/com.apple.TCC/TCC.db",
         NSHomeDirectory() + "/Library/Safari/Bookmarks.plist"]
    }

    /// True when any probe path is readable. `probe` is injectable so tests need not touch real TCC state.
    public static func isGranted(probe: (String) -> Bool = { FileManager.default.isReadableFile(atPath: $0) }) -> Bool {
        probePaths.contains(where: probe)
    }
}
