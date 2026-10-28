import Foundation

/// Throwaway storage for `SuiteFeature.snapshotViews()` and any other fixture code. Never use
/// `UserDefaults(suiteName: "some.name")` for fixtures: a plain suite name writes
/// `~/Library/Preferences/some.name.plist` on the user's Mac and leaves it there.
///
///     static func snapshotViews() -> FeatureSnapshotViews {
///         let settings = SoundSettings(defaults: SnapshotFixtures.defaults())
///         ...
///     }
enum SnapshotFixtures {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var created: [(suite: String, folder: URL)] = []
    nonisolated(unsafe) private static var cleanupRegistered = false

    /// A `UserDefaults` whose plist lives in its own temp folder (an absolute-path suite name), never in
    /// `~/Library/Preferences`. The domain and folder are removed when the process exits.
    static func defaults() -> UserDefaults {
        let (defaults, suite, folder) = makeDefaults()
        track(suite: suite, folder: folder)
        return defaults
    }

    /// Like `defaults()`, but you remove it yourself (call `cleanup` when done) instead of at exit.
    static func scopedDefaults() -> (defaults: UserDefaults, cleanup: () -> Void) {
        let (defaults, suite, folder) = makeDefaults()
        return (defaults, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: folder)
        })
    }

    /// A new, empty temp folder for fixture files (images, a fake history store), removed at exit.
    static func directory() -> URL {
        let folder = newFolder()
        track(suite: nil, folder: folder)
        return folder
    }

    // MARK: Internals

    private static func makeDefaults() -> (UserDefaults, String, URL) {
        let folder = newFolder()
        let suite = folder.appending(path: "prefs", directoryHint: .notDirectory).path
        guard let defaults = UserDefaults(suiteName: suite) else {
            preconditionFailure("SnapshotFixtures: no defaults suite at \(suite)")
        }
        return (defaults, suite, folder)
    }

    private static func newFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "orbit-fixture-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            preconditionFailure("SnapshotFixtures: couldn't create \(folder.path): \(error)")
        }
        return folder
    }

    private static func track(suite: String?, folder: URL) {
        lock.lock()
        defer { lock.unlock() }
        created.append((suite ?? "", folder))
        if !cleanupRegistered {
            cleanupRegistered = true
            atexit { SnapshotFixtures.removeAll() }
        }
    }

    /// Removes every tracked domain and folder (runs at exit).
    static func removeAll() {
        lock.lock()
        let items = created
        created.removeAll()
        lock.unlock()
        for item in items {
            if !item.suite.isEmpty { UserDefaults(suiteName: item.suite)?.removePersistentDomain(forName: item.suite) }
            try? FileManager.default.removeItem(at: item.folder)
        }
    }
}
