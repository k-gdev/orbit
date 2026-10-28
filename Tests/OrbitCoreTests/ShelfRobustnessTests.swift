import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// Shelf fix round 1: items on a drive that is offline are kept (not pruned), a damaged shelf file is
/// preserved, and the shake poller that replaces the dependence on global drag events.
@Suite struct ShelfRobustnessTests {
    // MARK: Availability (I1)

    /// A pretend file system: these paths exist, these answer with an error, everything else is absent.
    private static func probe(present: Set<String>, unavailable: Set<String> = []) -> (URL) -> ShelfProbeResult {
        { url in
            let path = url.standardizedFileURL.path
            if unavailable.contains(path) { return .unavailable }
            return present.contains(path) ? .exists : .absent
        }
    }

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func volumeRootComesFromThePath() {
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/NAS/Projects/a.psd")).path == "/Volumes/NAS")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/Backup Drive/x")).path == "/Volumes/Backup Drive")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/NAS")).path == "/Volumes/NAS")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Users/kevo/Desktop/a.txt")).path == "/")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes")).path == "/")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/System/Volumes/Data/Users/kevo/a")).path == "/")
    }

    @Test func aFileThatIsThereIsAvailable() {
        let probe = Self.probe(present: ["/Volumes/NAS/a.txt"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: probe) == .available)
    }

    /// The drive is up and the file is not on it: it really is gone, so the shelf may drop it.
    @Test func goneFileOnAMountedVolumeIsMissing() {
        let probe = Self.probe(present: ["/Volumes/NAS", "/Volumes/NAS/other.txt"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: probe) == .missing)
        // Same for a file on the startup disk.
        #expect(ShelfAvailability.status(of: Self.url("/Users/kevo/Desktop/a.txt"), probe: Self.probe(present: [])) == .missing)
    }

    /// The drive is not mounted (unplugged USB, sleeping or disconnected NAS): the file is not gone, it is
    /// out of reach, and the shelf must keep it.
    @Test func fileOnAnUnmountedVolumeIsUnreachableNotMissing() {
        let probe = Self.probe(present: ["/Volumes/Other"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/Projects/a.psd"), probe: probe) == .unreachable)
    }

    /// An error that is not "no such file" (permission denied, timeout, stale network handle) proves nothing
    /// about the file, so it is never treated as gone.
    @Test func anErrorIsNeverTreatedAsGone() {
        let denied = Self.probe(present: [], unavailable: ["/Users/kevo/Documents/a.pdf"])
        #expect(ShelfAvailability.status(of: Self.url("/Users/kevo/Documents/a.pdf"), probe: denied) == .unreachable)
        // The file is absent but the volume cannot be checked: still unreachable.
        let stuck = Self.probe(present: [], unavailable: ["/Volumes/NAS"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: stuck) == .unreachable)
    }

    @Test func errnoMapsToAProbeResult() {
        #expect(ShelfAvailability.probeResult(errnoValue: nil) == .exists)
        #expect(ShelfAvailability.probeResult(errnoValue: ENOENT) == .absent)
        #expect(ShelfAvailability.probeResult(errnoValue: ENOTDIR) == .absent)
        for code in [EACCES, EPERM, EIO, ETIMEDOUT, ESTALE, ENXIO, EINTR, ENOTCONN] {
            #expect(ShelfAvailability.probeResult(errnoValue: code) == .unavailable, "errno \(code)")
        }
    }

    @Test func realProbeSeesTheFilesystem() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Fixtures.file("here.txt", "x", in: dir)
        #expect(ShelfAvailability.probe(file) == .exists)
        #expect(ShelfAvailability.probe(dir) == .exists)
        #expect(ShelfAvailability.probe(dir.appending(path: "nope.txt")) == .absent)
        // A path that goes through a file is "not a directory", still plainly absent.
        #expect(ShelfAvailability.probe(file.appending(path: "inside.txt")) == .absent)
        // A temp folder is on the startup disk, so a deleted file there is genuinely missing.
        try FileManager.default.removeItem(at: file)
        #expect(ShelfAvailability.status(of: file, probe: ShelfAvailability.probe) == .missing)
    }

    // MARK: Shake poller (the wheel-style polling that replaces global drag events)

    /// x positions of a right-left zig-zag of `legs` legs of 100 pt, `samplesPerLeg` samples each.
    private static func zigzagXs(legs: Int, samplesPerLeg: Int = 6) -> [Double] {
        var xs = [600.0]
        var sign = 1.0
        for _ in 0..<legs {
            for _ in 0..<samplesPerLeg { xs.append(xs[xs.count - 1] + sign * 100 / Double(samplesPerLeg)) }
            sign = -sign
        }
        return xs
    }

    @Test func pollerStopsWhenTheButtonIsReleased() {
        var poller = ShakePoller()
        poller.buttonDown(changeCount: 4)
        #expect(poller.tick(buttonDown: true, changeCount: 4, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 1) == .waiting)
        #expect(poller.tick(buttonDown: false, changeCount: 4, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 1.02) == .stop)
    }

    @Test func pollerLeavesThePasteboardAloneUntilItChanges() {
        var poller = ShakePoller()
        poller.buttonDown(changeCount: 4)
        var reads = 0
        for step in 0..<10 {
            let outcome = poller.tick(buttonDown: true, changeCount: 4, hasFiles: { reads += 1; return true },
                                      point: CGPoint(x: 600 + Double(step), y: 400), time: 1 + Double(step) * 0.05)
            #expect(outcome == .waiting)
        }
        // A file URL left from an earlier drag, with no new drag started: never looked at.
        #expect(reads == 0)
    }

    @Test func pollerIgnoresATextDragEvenWhenShakenHard() {
        var poller = ShakePoller()
        poller.buttonDown(changeCount: 4)
        var reads = 0
        var time = 1.0
        for x in Self.zigzagXs(legs: 12) {
            time += 1.0 / 60
            // The drag pasteboard changed (a text drag began) but holds no file URL.
            let outcome = poller.tick(buttonDown: true, changeCount: 5, hasFiles: { reads += 1; return false },
                                      point: CGPoint(x: x, y: 400), time: time)
            #expect(outcome == .waiting)
        }
        // Types are read once per change, not on every tick.
        #expect(reads == 1)
    }

    @Test func pollerReportsAShakeOnlyForAFileDrag() {
        var poller = ShakePoller()
        poller.buttonDown(changeCount: 4)
        var outcomes: [ShakePoller.Outcome] = []
        var time = 1.0
        for x in Self.zigzagXs(legs: 6) {
            time += 1.0 / 60
            outcomes.append(poller.tick(buttonDown: true, changeCount: 5, hasFiles: { true }, point: CGPoint(x: x, y: 400), time: time))
        }
        // Tracking from the first tick of the file drag (the caller switches to the fast timer), one shake, then
        // tracking again while the lockout swallows the rest of the same shake.
        #expect(outcomes.first == .tracking)
        let shakes = outcomes.filter { if case .shake = $0 { return true } else { return false } }
        #expect(shakes.count == 1)
        let shakeIndex = outcomes.firstIndex { if case .shake = $0 { return true } else { return false } }
        #expect((shakeIndex ?? 0) > 3 * 6) // not before the third reversal
        #expect(outcomes.last == .tracking)
    }

    @Test func pollerStartsFreshOnTheNextPress() {
        var poller = ShakePoller()
        poller.buttonDown(changeCount: 4)
        _ = poller.tick(buttonDown: true, changeCount: 5, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 1)
        _ = poller.tick(buttonDown: false, changeCount: 5, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 1.1)
        // The next press: the pasteboard (5) is the new baseline, so its old file URL no longer counts.
        poller.buttonDown(changeCount: 5)
        #expect(poller.tick(buttonDown: true, changeCount: 5, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 2) == .waiting)
        #expect(poller.tick(buttonDown: true, changeCount: 6, hasFiles: { true }, point: CGPoint(x: 600, y: 400), time: 2.05) == .tracking)
    }

    @Test func pollIntervalsKeepIdleCostLowAndShakingResponsive() {
        #expect(ShakePoller.waitingInterval >= 0.04)   // at most ~25 looks at the pasteboard a second until a file drag starts
        #expect(ShakePoller.trackingInterval <= 1.0 / 30) // fine enough to see a 40 pt leg that takes 0.1 s
    }

    // MARK: Store hardening (M3)

    /// A throwaway folder holding a store directory and real files.
    private struct StoreFixture {
        let root = Fixtures.tempDir()
        var storeDirectory: URL { root.appending(path: "Shelf", directoryHint: .isDirectory) }
        var shelfFile: URL { storeDirectory.appending(path: ShelfStore.fileName, directoryHint: .notDirectory) }
        func file(_ name: String) -> URL { Fixtures.file(name, name, in: root) }
        func write(_ text: String) throws {
            try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
            try Data(text.utf8).write(to: shelfFile)
        }
        func backups() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: storeDirectory.path)) ?? [])
                .filter { $0 != ShelfStore.fileName }.sorted()
        }
        func contents(of name: String) -> String? {
            try? String(contentsOf: storeDirectory.appending(path: name), encoding: .utf8)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private static let fixedDate = Date(timeIntervalSince1970: 1_793_000_000) // 2026-10-26 07:33:20 UTC

    @Test func aCorruptShelfFileIsMovedAsideBeforeTheFirstSave() throws {
        let f = StoreFixture()
        defer { f.remove() }
        try f.write("this is not json")
        let store = ShelfStore(directory: f.storeDirectory, now: { Self.fixedDate })
        #expect(store.load().isEmpty)
        // Loading changes nothing on disk: the damaged file is still there, untouched.
        #expect(f.contents(of: ShelfStore.fileName) == "this is not json")
        #expect(f.backups().isEmpty)

        // The first save keeps it under another name before writing the new shelf.
        let kept = f.file("kept.txt")
        try store.save(ShelfItems([kept]))
        #expect(f.backups() == ["shelf.json.corrupt-20261026-073320"])
        #expect(f.contents(of: "shelf.json.corrupt-20261026-073320") == "this is not json")
        #expect(ShelfStore(directory: f.storeDirectory).load().urls.map(\.lastPathComponent) == ["kept.txt"])
        // Later saves have nothing more to preserve.
        try store.save(ShelfItems([kept, f.file("two.txt")]))
        #expect(f.backups().count == 1)
    }

    @Test func aBackupNeverOverwritesAnEarlierOne() throws {
        let f = StoreFixture()
        defer { f.remove() }
        let kept = f.file("kept.txt")
        for text in ["first damage", "second damage", "third damage"] {
            try f.write(text)
            let store = ShelfStore(directory: f.storeDirectory, now: { Self.fixedDate }) // the same second every time
            _ = store.load()
            try store.save(ShelfItems([kept]))
        }
        #expect(f.backups() == ["shelf.json.corrupt-20261026-073320", "shelf.json.corrupt-20261026-073320-2",
                                "shelf.json.corrupt-20261026-073320-3"])
        #expect(f.contents(of: "shelf.json.corrupt-20261026-073320") == "first damage")
        #expect(f.contents(of: "shelf.json.corrupt-20261026-073320-2") == "second damage")
        #expect(f.contents(of: "shelf.json.corrupt-20261026-073320-3") == "third damage")
    }

    @Test func aNewerVersionIsReadAsFarAsPossibleAndPreserved() throws {
        let f = StoreFixture()
        defer { f.remove() }
        let kept = f.file("kept.txt")
        let original = #"{"version": 99, "items": [{"path": "\#(kept.path)", "color": "red"}], "extra": true}"#
        try f.write(original)
        let store = ShelfStore(directory: f.storeDirectory, now: { Self.fixedDate })
        #expect(store.load().urls.map(\.lastPathComponent) == ["kept.txt"])
        try store.save(ShelfItems([kept]))
        // What a newer Orbit wrote is kept whole, and ours is written as our own version.
        #expect(f.backups() == ["shelf.json.newer-20261026-073320"])
        #expect(f.contents(of: "shelf.json.newer-20261026-073320") == original)
        let rewritten = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: f.shelfFile)) as? [String: Any])
        #expect(rewritten["version"] as? Int == 1)
    }

    @Test func oneBadEntryDoesNotDiscardTheRest() throws {
        let f = StoreFixture()
        defer { f.remove() }
        let a = f.file("a.txt")
        let b = f.file("b.txt")
        let damaged = #"{"version":1,"items":[{"path":"\#(a.path)"},{"nope":1},"junk",{"path":"\#(b.path)","bookmark":"!!notbase64"}]}"#
        try f.write(damaged)
        let store = ShelfStore(directory: f.storeDirectory, now: { Self.fixedDate })
        // The two readable entries survive (a bookmark that can't be read just means no bookmark).
        #expect(store.load().urls.map(\.lastPathComponent) == ["a.txt", "b.txt"])
        // The original, bad entries included, is kept before the first save rewrites the file.
        try store.save(ShelfItems([a, b]))
        #expect(f.backups() == ["shelf.json.corrupt-20261026-073320"])
        #expect(f.contents(of: "shelf.json.corrupt-20261026-073320") == damaged)
    }

    @Test func aCleanShelfFileMakesNoBackups() throws {
        let f = StoreFixture()
        defer { f.remove() }
        let kept = f.file("kept.txt")
        let store = ShelfStore(directory: f.storeDirectory)
        try store.save(ShelfItems([kept]))
        let again = ShelfStore(directory: f.storeDirectory)
        #expect(again.load().count == 1)
        try again.save(ShelfItems())
        #expect(f.backups().isEmpty)
        // No file at all is not damage either.
        let empty = StoreFixture()
        defer { empty.remove() }
        let fresh = ShelfStore(directory: empty.storeDirectory)
        #expect(fresh.load().isEmpty)
        try fresh.save(ShelfItems([empty.file("x.txt")]))
        #expect(empty.backups().isEmpty)
    }

    @Test func ifTheDamagedFileCannotBeKeptItIsNotOverwritten() throws {
        struct Refused: Error {}
        let f = StoreFixture()
        defer { f.remove() }
        try f.write("precious but unreadable")
        let store = ShelfStore(directory: f.storeDirectory, now: { Self.fixedDate }, moveItem: { _, _ in throw Refused() })
        #expect(store.load().isEmpty)
        #expect(throws: (any Error).self) { try store.save(ShelfItems([f.file("kept.txt")])) }
        #expect(f.contents(of: ShelfStore.fileName) == "precious but unreadable")
    }

    @Test func loadStoredNeverTouchesTheFilesItListsAndLoadFollowsMovedOnes() throws {
        let f = StoreFixture()
        defer { f.remove() }
        let original = f.file("before.txt")
        let store = ShelfStore(directory: f.storeDirectory)
        try store.save(ShelfItems([original, URL(fileURLWithPath: "/Volumes/Gone Drive/never-here.txt")]))
        let renamed = f.root.appending(path: "after.txt")
        try FileManager.default.moveItem(at: original, to: renamed)

        // `loadStored` answers from shelf.json alone: the paths as saved, whether or not they exist.
        let stored = ShelfStore(directory: f.storeDirectory).loadStored()
        #expect(stored.urls.map(\.lastPathComponent) == ["before.txt", "never-here.txt"])
        // `follow` finds the renamed file through its bookmark, and has nothing for the one on the missing drive.
        let reader = ShelfStore(directory: f.storeDirectory)
        _ = reader.loadStored()
        #expect(reader.follow(original)?.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
        #expect(reader.follow(URL(fileURLWithPath: "/Volumes/Gone Drive/never-here.txt")) == nil)
        // `load` is `loadStored` plus following.
        let full = ShelfStore(directory: f.storeDirectory).load()
        #expect(full.urls.map(\.lastPathComponent) == ["after.txt", "never-here.txt"])
    }
}
