import Foundation
import Testing
@testable import OrbitCore

/// Noticing files leave the shelf while it is open: which folders to watch, which file system events matter,
/// and the FSEvents stream itself (against a real temporary folder).
@Suite struct ShelfWatchTests {
    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    private static func paths(_ folders: [URL]) -> [String] { folders.map(\.path) }

    // MARK: Folders to watch

    @Test func watchesTheDistinctParentFolders() {
        let plan = ShelfWatchPlan(items: [Self.url("/Users/kevo/Desktop/b.txt"), Self.url("/Users/kevo/Desktop/a.txt"),
                                          Self.url("/Users/kevo/Downloads/c.pdf"), Self.url("/Volumes/NAS/Projects/d.psd")])
        #expect(Self.paths(plan.folders) == ["/Users/kevo/Desktop", "/Users/kevo/Downloads", "/Volumes/NAS/Projects"])
    }

    @Test func aFolderItemIsWatchedThroughItsParentNotItself() {
        // Moving or trashing the folder shows up in the folder it sits in.
        let plan = ShelfWatchPlan(items: [Self.url("/Users/kevo/Projects/site/"), Self.url("/Users/kevo/Projects/notes.md")])
        #expect(Self.paths(plan.folders) == ["/Users/kevo/Projects"])
    }

    @Test func pathsAreStandardisedBeforeGrouping() {
        let plan = ShelfWatchPlan(items: [Self.url("/Users/kevo/Desktop/a.txt"), Self.url("/Users/kevo/Desktop/../Desktop/b.txt")])
        #expect(Self.paths(plan.folders) == ["/Users/kevo/Desktop"])
    }

    @Test func itemsThatCannotBeReachedAreNotWatched() {
        let offline = Self.url("/Volumes/NAS/Projects/d.psd")
        let plan = ShelfWatchPlan(items: [Self.url("/Users/kevo/Desktop/a.txt"), offline,
                                          Self.url("/Volumes/NAS/Projects/e.psd")],
                                  skipping: [offline])
        // The folder stays because another item in it is reachable.
        #expect(Self.paths(plan.folders) == ["/Users/kevo/Desktop", "/Volumes/NAS/Projects"])
        let alone = ShelfWatchPlan(items: [Self.url("/Users/kevo/Desktop/a.txt"), offline], skipping: [offline])
        #expect(Self.paths(alone.folders) == ["/Users/kevo/Desktop"])
        // An item skipped by a differently spelled URL is still skipped.
        let spelled = ShelfWatchPlan(items: [offline], skipping: [Self.url("/Volumes/NAS/Projects/../Projects/d.psd")])
        #expect(spelled.isEmpty)
    }

    @Test func nothingIsWatchedForAnEmptyShelfOrAFileAtTheDiskRoot() {
        #expect(ShelfWatchPlan(items: []).isEmpty)
        #expect(ShelfWatchPlan(items: []).folders.isEmpty)
        // Watching "/" would mean every change on the disk.
        #expect(ShelfWatchPlan(items: [Self.url("/stray.txt")]).isEmpty)
        // Not a file: nothing to watch.
        #expect(ShelfWatchPlan(items: [URL(string: "https://example.com/a.txt")!]).isEmpty)
    }

    // MARK: Which events matter

    private static let plan = ShelfWatchPlan(items: [Self.url("/Users/kevo/Desktop/report.pdf"), Self.url("/Users/kevo/Desktop/site"),
                                                     Self.url("/Volumes/NAS/Projects/d.psd")])

    @Test func anEventOnAnItemMatters() {
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/report.pdf"]))
        #expect(Self.plan.isRelevant(["/Volumes/NAS/Projects/d.psd"]))
        // Among others that don't matter.
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/.DS_Store", "/Users/kevo/Desktop/other.txt", "/Users/kevo/Desktop/report.pdf"]))
        // The same path spelled with a trailing slash (a folder event).
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/site/"]))
    }

    @Test func anEventInsideAFolderItemMatters() {
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/site/index.html"]))
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/site/css/main.css"]))
    }

    @Test func anEventOnTheParentFolderItselfMatters() {
        // The folder was renamed, moved or removed.
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop"]))
        #expect(Self.plan.isRelevant(["/Users/kevo/Desktop/"]))
        // So does one on a folder above it.
        #expect(Self.plan.isRelevant(["/Users/kevo"]))
        #expect(Self.plan.isRelevant(["/Volumes/NAS"]))
    }

    @Test func eventsOnOtherFilesDoNot() {
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop/other.txt"]))
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop/.DS_Store"]))
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop/other/report.pdf"]))      // same name, another folder
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop/report.pdf.download"]))   // the name is only a prefix
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop/sites/index.html"]))      // a sibling folder
        #expect(!Self.plan.isRelevant(["/Users/kevo/Downloads/report.pdf"]))          // not a watched folder
        #expect(!Self.plan.isRelevant(["/Users/kevo/Desktop2"]))
        #expect(!Self.plan.isRelevant(["/Volumes/NAS2/Projects/d.psd"]))
        #expect(!Self.plan.isRelevant([]))
        #expect(!ShelfWatchPlan().isRelevant(["/Users/kevo/Desktop/report.pdf"]))
    }

    // MARK: Following a folder to where it really is

    @Test func mappingRewritesFoldersAndTheItemsInThem() {
        let mapped = Self.plan.mapping { folder in
            folder.path == "/Users/kevo/Desktop" ? Self.url("/System/Volumes/Data/Users/kevo/Desktop") : folder
        }
        #expect(Self.paths(mapped.folders) == ["/System/Volumes/Data/Users/kevo/Desktop", "/Volumes/NAS/Projects"])
        #expect(mapped.isRelevant(["/System/Volumes/Data/Users/kevo/Desktop/report.pdf"]))
        #expect(mapped.isRelevant(["/System/Volumes/Data/Users/kevo/Desktop/site/a.html"]))
        #expect(!mapped.isRelevant(["/Users/kevo/Desktop/report.pdf"]))
    }

    @Test func mappingToNilDropsTheFolderAndItsItems() {
        let mapped = Self.plan.mapping { $0.path.hasPrefix("/Volumes") ? nil : $0 }
        #expect(Self.paths(mapped.folders) == ["/Users/kevo/Desktop"])
        #expect(!mapped.isRelevant(["/Volumes/NAS/Projects/d.psd"]))
        #expect(Self.plan.mapping { _ in nil }.isEmpty)
    }

    @Test func foldersThatMapToTheSamePlaceAreMerged() {
        let plan = ShelfWatchPlan(items: [Self.url("/a/one.txt"), Self.url("/alias/two.txt")])
        let mapped = plan.mapping { _ in Self.url("/real") }
        #expect(Self.paths(mapped.folders) == ["/real"])
        #expect(mapped.isRelevant(["/real/one.txt"]))
        #expect(mapped.isRelevant(["/real/two.txt"]))
    }

    // MARK: The real stream

    /// Counts calls from the watcher's queue.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// Waits (at most `timeout` seconds) until the counter passes `above`.
    private static func wait(_ counter: Counter, above: Int, timeout: TimeInterval = 8) async -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while counter.value <= above, Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return counter.value > above
    }

    /// FSEvents starts watching a moment after the stream is created, and reports the changes of the moments
    /// just before it too (the files the test made to have something to watch). Wait for both to be over, then
    /// say how many calls there are by now: the test counts from there.
    private static func settle(_ counter: Counter) async -> Int {
        try? await Task.sleep(for: .milliseconds(1500))
        return counter.value
    }

    @Test func aWatchedFileBeingRemovedCallsBack() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Fixtures.file("kept.txt", "k", in: dir)
        let doomed = Fixtures.file("doomed.txt", "d", in: dir)
        let counter = Counter()
        let watcher = ShelfFolderWatcher { counter.bump() }
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: [kept, doomed]))
        let base = await Self.settle(counter)
        try FileManager.default.removeItem(at: doomed)
        #expect(await Self.wait(counter, above: base))
    }

    @Test func aWatchedFileBeingRenamedCallsBack() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Fixtures.file("a.txt", "a", in: dir)
        let counter = Counter()
        let watcher = ShelfFolderWatcher { counter.bump() }
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: [file]))
        let base = await Self.settle(counter)
        try FileManager.default.moveItem(at: file, to: dir.appending(path: "b.txt"))
        #expect(await Self.wait(counter, above: base))
    }

    @Test func otherFilesInTheFolderAreIgnored() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let watched = Fixtures.file("watched.txt", "w", in: dir)
        let counter = Counter()
        let watcher = ShelfFolderWatcher(latency: 0.2) { counter.bump() }
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: [watched]))
        let base = await Self.settle(counter)
        let other = Fixtures.file("other.txt", "o", in: dir)
        try FileManager.default.removeItem(at: other)
        try await Task.sleep(for: .seconds(1.5))
        #expect(counter.value == base)
        // The stream is alive all the same.
        try FileManager.default.removeItem(at: watched)
        #expect(await Self.wait(counter, above: base))
    }

    @Test func aBurstOfChangesCallsBackOnce() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = (0..<5).map { Fixtures.file("f\($0).txt", "x", in: dir) }
        let counter = Counter()
        let watcher = ShelfFolderWatcher(latency: 0.5) { counter.bump() }
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: files))
        let base = await Self.settle(counter)
        for file in files { try FileManager.default.removeItem(at: file) }
        #expect(await Self.wait(counter, above: base))
        try await Task.sleep(for: .seconds(1.5))
        #expect(counter.value == base + 1)
    }

    @Test func aNewPlanRetargetsTheStream() async throws {
        let first = Fixtures.tempDir(), second = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let a = Fixtures.file("a.txt", "a", in: first)
        let b = Fixtures.file("b.txt", "b", in: second)
        let counter = Counter()
        let watcher = ShelfFolderWatcher(latency: 0.2) { counter.bump() }
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: [a]))
        watcher.watch(ShelfWatchPlan(items: [b])) // the shelf changed: only the second folder matters now
        let base = await Self.settle(counter)
        try FileManager.default.removeItem(at: a)
        try await Task.sleep(for: .seconds(1.5))
        #expect(counter.value == base)
        try FileManager.default.removeItem(at: b)
        #expect(await Self.wait(counter, above: base))
    }

    @Test func stoppedMeansSilent() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Fixtures.file("a.txt", "a", in: dir)
        let counter = Counter()
        let watcher = ShelfFolderWatcher(latency: 0.2) { counter.bump() }
        watcher.watch(ShelfWatchPlan(items: [file]))
        let base = await Self.settle(counter)
        watcher.stop()
        try FileManager.default.removeItem(at: file)
        try await Task.sleep(for: .seconds(1.5))
        #expect(counter.value == base)
        // And it can be started again.
        let again = Fixtures.file("again.txt", "a", in: dir)
        watcher.watch(ShelfWatchPlan(items: [again]))
        let restarted = await Self.settle(counter)
        try FileManager.default.removeItem(at: again)
        #expect(await Self.wait(counter, above: restarted))
        watcher.stop()
    }

    @Test func aFolderOnAVolumeThatIsNotThereIsLeftAlone() async throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Fixtures.file("a.txt", "a", in: dir)
        let counter = Counter()
        // The volume check says the NAS is down: its folder is never handed to FSEvents, and the rest still works.
        let watcher = ShelfFolderWatcher(latency: 0.2, folderTransform: { folder in
            folder.path.hasPrefix("/Volumes/") ? nil : ShelfFolderWatcher.reachableFolder(folder)
        }, onChange: { counter.bump() })
        defer { watcher.stop() }
        watcher.watch(ShelfWatchPlan(items: [URL(fileURLWithPath: "/Volumes/Orbit-Test-Not-Mounted/x.txt"), file]))
        let base = await Self.settle(counter)
        try FileManager.default.removeItem(at: file)
        #expect(await Self.wait(counter, above: base))
    }

    @Test func theDefaultFolderCheckSkipsMissingFoldersAndUnmountedVolumes() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(ShelfFolderWatcher.reachableFolder(dir) != nil)
        // Symbolic links are followed: FSEvents reports real paths (/var is /private/var).
        if dir.path.hasPrefix("/var/") {
            #expect(ShelfFolderWatcher.reachableFolder(dir)?.path == "/private" + dir.path)
        }
        #expect(ShelfFolderWatcher.reachableFolder(dir.appending(path: "gone", directoryHint: .isDirectory)) == nil)
        #expect(ShelfFolderWatcher.reachableFolder(URL(fileURLWithPath: "/Volumes/Orbit-Test-Not-Mounted/Projects")) == nil)
    }
}
