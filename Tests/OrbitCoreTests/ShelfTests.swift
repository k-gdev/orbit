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
}
