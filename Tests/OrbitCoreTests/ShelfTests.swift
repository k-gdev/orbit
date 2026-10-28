import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// Shelf (spec §5.6): shake detection, the shelf's items and their persistence, its settings, and the
/// wheel's Shelf action.
@Suite struct ShelfTests {
    // MARK: Shake detector

    /// A horizontal zig-zag sampled at 60 Hz: `legs` straight legs of `amplitude` points (the first one
    /// to the right, or to the left when `startsLeft`), each taking `legDuration` seconds.
    private static func zigzag(legs: Int, amplitude: Double, legDuration: Double, startsLeft: Bool = false,
                               startX: Double = 600, y: Double = 400, startTime: TimeInterval = 100) -> [(point: CGPoint, time: TimeInterval)] {
        var samples = [(point: CGPoint(x: startX, y: y), time: startTime)]
        let steps = max(Int((legDuration * 60).rounded()), 1)
        var x = startX
        var t = startTime
        var sign: Double = startsLeft ? -1 : 1
        for _ in 0..<legs {
            let stepDX = sign * amplitude / Double(steps)
            for _ in 0..<steps {
                x += stepDX
                t += legDuration / Double(steps)
                samples.append((CGPoint(x: x, y: y), t))
            }
            sign = -sign
        }
        return samples
    }

    /// Feeds `samples` and returns the index of the first one that reports a shake.
    private static func firstShake(in samples: [(point: CGPoint, time: TimeInterval)],
                                   using detector: inout ShakeDetector) -> Int? {
        for (index, sample) in samples.enumerated() where detector.feed(sample.point, at: sample.time) {
            return index
        }
        return nil
    }

    @Test func shakeDetectedAfterThreeReversals() {
        var detector = ShakeDetector()
        // Right, left, right, left: the turn after the third leg is the third reversal.
        let samples = Self.zigzag(legs: 5, amplitude: 100, legDuration: 0.1)
        let hit = Self.firstShake(in: samples, using: &detector)
        #expect(hit != nil)
        // It reports during the fourth leg, not before the third reversal has happened.
        let thirdLegEnd = 3 * 6 // 6 samples per 0.1 s leg
        #expect((hit ?? 0) > thirdLegEnd)
        // The same gesture starting to the left is a shake too.
        var other = ShakeDetector()
        #expect(Self.firstShake(in: Self.zigzag(legs: 5, amplitude: 100, legDuration: 0.1, startsLeft: true), using: &other) != nil)
    }

    @Test func twoReversalsAreNotEnough() {
        var detector = ShakeDetector()
        // Right, left, right: two reversals.
        let samples = Self.zigzag(legs: 3, amplitude: 100, legDuration: 0.1)
        #expect(Self.firstShake(in: samples, using: &detector) == nil)
    }

    @Test func slowWiggleIsNotShake() {
        var detector = ShakeDetector()
        // Plenty of long legs, but each takes 0.4 s, so three reversals never fit in 0.6 s.
        let samples = Self.zigzag(legs: 12, amplitude: 100, legDuration: 0.4)
        #expect(Self.firstShake(in: samples, using: &detector) == nil)
    }

    @Test func smallJitterIsNotShake() {
        var detector = ShakeDetector()
        // Fast, but every leg is 30 pt, under the 40 pt minimum.
        let samples = Self.zigzag(legs: 30, amplitude: 30, legDuration: 0.05)
        #expect(Self.firstShake(in: samples, using: &detector) == nil)
    }

    @Test func verticalShakingIsNotShake() {
        var detector = ShakeDetector()
        // Only horizontal reversals count: shake up and down while x stays put.
        var t: TimeInterval = 100
        var hit = false
        for index in 0..<120 {
            t += 1.0 / 60
            let y = 400 + (index / 6 % 2 == 0 ? 1 : -1) * Double(index % 6) * 20
            if detector.feed(CGPoint(x: 600, y: y), at: t) { hit = true }
        }
        #expect(!hit)
    }

    @Test func resetForgetsProgress() {
        var detector = ShakeDetector()
        // Two reversals' worth, then a reset, then two reversals' worth again: neither alone is a shake.
        let first = Self.zigzag(legs: 3, amplitude: 100, legDuration: 0.1, startTime: 100)
        #expect(Self.firstShake(in: first, using: &detector) == nil)
        detector.reset()
        // (It carries on from where the first half stopped: x = 600 + 100.)
        let second = Self.zigzag(legs: 3, amplitude: 100, legDuration: 0.1, startX: 700, startTime: 100.4)
        #expect(Self.firstShake(in: second, using: &detector) == nil)
        // Without the reset the same two halves add up to a shake.
        var joined = ShakeDetector()
        #expect(Self.firstShake(in: first + second, using: &joined) != nil)
    }

    @Test func reportsOncePerShake() {
        var detector = ShakeDetector()
        let samples = Self.zigzag(legs: 12, amplitude: 100, legDuration: 0.1)
        let hits = samples.filter { detector.feed($0.point, at: $0.time) }.count
        // 1.2 s of continuous shaking: the first report, then the lockout swallows the rest.
        #expect(hits == 1)
    }

    @Test func staleTimestampsStartOver() {
        var detector = ShakeDetector()
        let samples = Self.zigzag(legs: 3, amplitude: 100, legDuration: 0.1, startTime: 500)
        #expect(Self.firstShake(in: samples, using: &detector) == nil)
        // Time going backwards (a new session) must not combine with the old reversals.
        let fresh = Self.zigzag(legs: 3, amplitude: 100, legDuration: 0.1, startTime: 10)
        #expect(Self.firstShake(in: fresh, using: &detector) == nil)
    }

    // MARK: File drag gate

    /// The drag pasteboard keeps the last drag's contents, so "it holds file URLs" alone would also be
    /// true while selecting text with the mouse. Only a pasteboard that changed since the button went
    /// down, and holds files, means a file drag is under way.
    @Test func dragGateIgnoresStalePasteboard() {
        var gate = FileDragGate()
        #expect(!gate.isFileDrag(changeCount: 5, hasFiles: true)) // no button yet
        gate.buttonDown(changeCount: 5)
        #expect(!gate.isFileDrag(changeCount: 5, hasFiles: true)) // left over from an earlier drag
        #expect(gate.isFileDrag(changeCount: 6, hasFiles: true))  // this drag wrote it
        #expect(!gate.isFileDrag(changeCount: 6, hasFiles: false)) // a text or image drag
        gate.buttonUp()
        #expect(!gate.isFileDrag(changeCount: 6, hasFiles: true))
        // The next press starts from the pasteboard as it is then.
        gate.buttonDown(changeCount: 6)
        #expect(!gate.isFileDrag(changeCount: 6, hasFiles: true))
        #expect(gate.isFileDrag(changeCount: 7, hasFiles: true))
    }

    // MARK: Items

    private static let a = URL(fileURLWithPath: "/tmp/shelf/a.txt")
    private static let b = URL(fileURLWithPath: "/tmp/shelf/b.png")
    private static let c = URL(fileURLWithPath: "/tmp/shelf/c folder", isDirectory: true)

    @Test func itemsUniqueAndOrdered() {
        var items = ShelfItems()
        #expect(items.isEmpty)
        // Adding returns what was new; a repeated file keeps its first place.
        let first = items.add([Self.a, Self.b, Self.a])
        #expect(first == [Self.a, Self.b])
        #expect(items.urls == [Self.a, Self.b])
        let again = items.add(Self.a)
        #expect(!again)
        let addedC = items.add(Self.c)
        #expect(addedC)
        #expect(items.urls == [Self.a, Self.b, Self.c])
        #expect(items.count == 3)
        #expect(items.contains(Self.b))
        // The same file spelled another way is the same item (".." segments, folder slash).
        let dotted = items.add(URL(fileURLWithPath: "/tmp/shelf/x/../a.txt"))
        #expect(!dotted)
        let slashless = items.add(URL(fileURLWithPath: "/tmp/shelf/c folder"))
        #expect(!slashless)
        #expect(items.contains(URL(fileURLWithPath: "/tmp/shelf/c folder/")))
        #expect(items.count == 3)
        // Only files: a web URL is not a shelf item.
        let web = items.add(URL(string: "https://example.com/a.txt")!)
        #expect(!web)
        // Removing keeps the order of the rest, and a removed file can come back (at the end).
        items.remove(Self.b)
        #expect(items.urls == [Self.a, Self.c])
        items.remove(Self.b)
        #expect(items.urls == [Self.a, Self.c])
        let readded = items.add(Self.b)
        #expect(readded)
        #expect(items.urls == [Self.a, Self.c, Self.b])
        items.removeAll()
        #expect(items.isEmpty)
    }

    @Test func removeMissing() {
        var items = ShelfItems([Self.a, Self.b, Self.c])
        let present: Set<URL> = [Self.a, Self.c]
        let removed = items.removeMissing(fileExists: { present.contains($0) })
        #expect(removed == [Self.b])
        #expect(items.urls == [Self.a, Self.c])
        // Nothing missing: nothing removed.
        let none = items.removeMissing(fileExists: { _ in true })
        #expect(none.isEmpty)
        #expect(items.urls == [Self.a, Self.c])
    }

    @Test func removeMissingChecksTheRealFilesystem() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let kept = Fixtures.file("kept.txt", "hello", in: dir)
        let gone = Fixtures.file("gone.txt", "bye", in: dir)
        var items = ShelfItems([kept, gone])
        try FileManager.default.removeItem(at: gone)
        let removed = items.removeMissing()
        #expect(removed == [gone])
        #expect(items.urls == [kept])
    }

    // MARK: Store

    /// A throwaway folder with a few real files, and a store whose folder does not exist yet.
    private struct StoreFixture {
        let root = Fixtures.tempDir()
        var storeDirectory: URL { root.appending(path: "Shelf", directoryHint: .isDirectory) }
        var store: ShelfStore { ShelfStore(directory: storeDirectory) }
        func file(_ name: String, _ text: String = "x") -> URL { Fixtures.file(name, text, in: root) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func storeRoundTrip() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let one = fixture.file("one.txt")
        let two = fixture.file("two with spaces.png")
        let folder = fixture.root.appending(path: "a folder", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let store = fixture.store
        // Nothing saved yet: an empty shelf, and loading did not create anything.
        #expect(store.load().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.storeDirectory.path))

        try store.save(ShelfItems([one, two, folder]))
        // A new store on the same folder (a relaunch) sees the same items in the same order.
        let loaded = ShelfStore(directory: fixture.storeDirectory).load()
        #expect(loaded.urls.map(\.path) == [one, two, folder].map { $0.standardizedFileURL.path })

        // The file is JSON: a path and bookmark data per item, with no security scope involved.
        let data = try Data(contentsOf: store.fileURL)
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(root["items"] as? [[String: Any]])
        #expect(entries.count == 3)
        #expect(entries.allSatisfy { ($0["path"] as? String)?.hasPrefix("/") == true })
        #expect(entries.allSatisfy { ($0["bookmark"] as? String)?.isEmpty == false })

        // Saving an empty shelf empties it.
        try store.save(ShelfItems())
        #expect(ShelfStore(directory: fixture.storeDirectory).load().isEmpty)
    }

    @Test func storeFindsAMovedFileThroughItsBookmark() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let original = fixture.file("before.txt", "hello")
        try fixture.store.save(ShelfItems([original]))
        let renamed = fixture.root.appending(path: "after.txt", directoryHint: .notDirectory)
        try FileManager.default.moveItem(at: original, to: renamed)

        let loaded = ShelfStore(directory: fixture.storeDirectory).load()
        #expect(loaded.count == 1)
        // /var and /private/var are the same place; compare what the files really are.
        #expect(loaded.urls.first?.resolvingSymlinksInPath().path == renamed.resolvingSymlinksInPath().path)
    }

    @Test func storeKeepsAMissingFileByPath() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        let gone = fixture.file("gone.txt")
        try fixture.store.save(ShelfItems([gone]))
        try FileManager.default.removeItem(at: gone)
        // Not found by path or bookmark: still listed (at its old path) so the caller decides to prune it.
        var loaded = ShelfStore(directory: fixture.storeDirectory).load()
        #expect(loaded.urls.map(\.path) == [gone.standardizedFileURL.path])
        let removed = loaded.removeMissing()
        #expect(removed.count == 1)
        #expect(loaded.isEmpty)
    }

    @Test func storeSurvivesUnreadableData() throws {
        let fixture = StoreFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.storeDirectory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fixture.store.fileURL)
        #expect(fixture.store.load().isEmpty)
        // A shelf file written by something that doesn't know the format is ignored, not a crash.
        try Data(#"{"items": [{"nope": 1}]}"#.utf8).write(to: fixture.store.fileURL, options: .atomic)
        #expect(fixture.store.load().isEmpty)
    }

    // MARK: Settings

    @Test func settingsRoundTrip() {
        let (d, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let fresh = ShelfSettings(defaults: d)
        #expect(fresh.shakeToOpen)
        #expect(fresh.keepOnTop)
        #expect(fresh.lastFrame(forScreen: "screen-a") == nil)

        fresh.shakeToOpen = false
        fresh.keepOnTop = false
        let frameA = CGRect(x: 120, y: 80, width: 520, height: 190)
        let frameB = CGRect(x: -1500, y: 40, width: 300, height: 140)
        fresh.setLastFrame(frameA, forScreen: "screen-a")
        fresh.setLastFrame(frameB, forScreen: "screen-b")

        let reloaded = ShelfSettings(defaults: d)
        #expect(!reloaded.shakeToOpen)
        #expect(!reloaded.keepOnTop)
        #expect(reloaded.lastFrame(forScreen: "screen-a") == frameA)
        #expect(reloaded.lastFrame(forScreen: "screen-b") == frameB)
        #expect(reloaded.lastFrame(forScreen: "screen-c") == nil)
        // Keys carry the feature id.
        #expect(d.object(forKey: "shelf.shakeToOpen") as? Bool == false)
        #expect(d.object(forKey: "shelf.keepOnTop") as? Bool == false)

        // Forgetting one screen leaves the other.
        reloaded.setLastFrame(nil, forScreen: "screen-a")
        let again = ShelfSettings(defaults: d)
        #expect(again.lastFrame(forScreen: "screen-a") == nil)
        #expect(again.lastFrame(forScreen: "screen-b") == frameB)
    }

    @Test func settingsIgnoreUnusableFrames() {
        let (d, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        d.set(Data("junk".utf8), forKey: "shelf.frames")
        #expect(ShelfSettings(defaults: d).lastFrame(forScreen: "screen-a") == nil)
        // A saved frame with no area is no use; it is not stored in the first place.
        let settings = ShelfSettings(defaults: d)
        settings.setLastFrame(CGRect(x: 10, y: 10, width: 0, height: 0), forScreen: "screen-a")
        #expect(ShelfSettings(defaults: d).lastFrame(forScreen: "screen-a") == nil)
    }

    // MARK: Placement

    private static let screen = CGRect(x: 0, y: 25, width: 1600, height: 875)
    private static let leftScreen = CGRect(x: -1920, y: -100, width: 1920, height: 1055)

    @Test func placementCentresOnThePointer() {
        let size = CGSize(width: 440, height: 168)
        let frame = ShelfPlacement.frame(size: size, centeredOn: CGPoint(x: 800, y: 450), in: Self.screen)
        #expect(frame == CGRect(x: 580, y: 366, width: 440, height: 168))
    }

    @Test func placementKeepsTheShelfOnScreen() {
        let size = CGSize(width: 440, height: 168)
        for visible in [Self.screen, Self.leftScreen] {
            for point in [CGPoint(x: visible.minX, y: visible.minY), CGPoint(x: visible.maxX, y: visible.maxY),
                          CGPoint(x: visible.minX + 5, y: visible.maxY - 5), CGPoint(x: visible.maxX - 5, y: visible.minY + 5)] {
                let frame = ShelfPlacement.frame(size: size, centeredOn: point, in: visible)
                #expect(visible.contains(frame), "\(frame) should lie in \(visible)")
                #expect(frame.size == size)
            }
        }
        // A shelf bigger than the screen shrinks to fit rather than hang off it.
        let huge = ShelfPlacement.frame(size: CGSize(width: 3000, height: 2000), centeredOn: CGPoint(x: 10, y: 10), in: Self.screen)
        #expect(huge == Self.screen)
    }

    @Test func restoredFrameMovesBackOntoTheScreen() {
        // The display it was on is gone: the frame is pulled onto the screen it opens on, size unchanged.
        let saved = CGRect(x: 4000, y: 3000, width: 520, height: 190)
        let frame = ShelfPlacement.restored(saved, in: Self.screen)
        #expect(Self.screen.contains(frame))
        #expect(frame.size == saved.size)
        // A frame that already fits is left alone.
        let fine = CGRect(x: 200, y: 100, width: 520, height: 190)
        #expect(ShelfPlacement.restored(fine, in: Self.screen) == fine)
    }

    @Test func defaultFrameSitsAtTheBottomCentre() {
        let frame = ShelfPlacement.defaultFrame(size: CGSize(width: 440, height: 168), in: Self.screen)
        #expect(frame.midX == Self.screen.midX)
        #expect(frame.minY > Self.screen.minY)
        #expect(frame.minY < Self.screen.midY)
        #expect(Self.screen.contains(frame))
    }
}
