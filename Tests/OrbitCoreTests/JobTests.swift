import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// Lock-protected value, so `@Sendable` closures can record test state.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.lock(); defer { lock.unlock() }; return stored }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); defer { lock.unlock() }; body(&stored) }
}

private struct TrashOutsideTestRoot: Error { let url: URL }

/// Records the units it receives, then runs a scripted handler (by default: write `<stem>-converted.txt`).
private final class FakeProcessor: Processor {
    typealias Handler = @Sendable (JobRequest, JobContext) async throws -> ProcessorOutput

    private let recorded = Locked<[[DroppedItem]]>([])
    private let accepts: @Sendable (JobRequest) -> Bool
    private let handler: Handler

    init(handler: @escaping Handler = { r, c in try writeConverted(r, c) },
         accepts: @escaping @Sendable (JobRequest) -> Bool = { _ in true }) {
        self.accepts = accepts
        self.handler = handler
    }

    var units: [[DroppedItem]] { recorded.value }

    func canHandle(_ request: JobRequest) -> Bool { accepts(request) }

    func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        recorded.mutate { $0.append(request.items) }
        return try await handler(request, context)
    }
}

/// Writes at a reserved URL, refusing to overwrite: a reservation must never point at an existing file.
private func write(_ url: URL, _ text: String = "out") throws -> URL {
    try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    return url
}

private func writeConverted(_ r: JobRequest, _ c: JobContext) throws -> ProcessorOutput {
    ProcessorOutput(outputs: try r.items.map { try write(c.outputURL($0.url, "converted", "txt")) })
}

private func named(_ name: String, in r: JobRequest) -> Bool {
    r.items.contains { $0.url.lastPathComponent == name }
}

private func failsOn(_ name: String, afterWriting: Bool) -> FakeProcessor {
    FakeProcessor { r, c in
        guard named(name, in: r) else { return try writeConverted(r, c) }
        if afterWriting { _ = try writeConverted(r, c) }
        throw OrbitError.unsupported("\(name) is broken")
    }
}

private func alwaysFails(_ message: String) -> FakeProcessor {
    FakeProcessor { _, _ in throw OrbitError.unsupported(message) }
}

private func cancelsOn(_ name: String) -> FakeProcessor {
    FakeProcessor { r, c in
        let out = try writeConverted(r, c)
        if named(name, in: r) { throw OrbitError.cancelled }
        return out
    }
}

private func loose(_ name: String) -> DroppedItem { DroppedItem(url: URL(filePath: "/nonexistent/\(name)")) }

@Suite final class JobTests {
    let root = Fixtures.tempDir()
    let dir: URL
    let fallback: URL
    private let trashed = Locked<[URL]>([])
    private let ok = FakeProcessor()
    private let rec = FakeProcessor()
    private var sources: [URL] = []

    init() throws {
        dir = root.appending(path: "src", directoryHint: .isDirectory)
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// Every URL the runner passed to the injected `trash`.
    var trashLog: [URL] { trashed.value }

    private func runner(_ processors: [any Processor], writable: Bool = true) -> JobRunner {
        let log = trashed
        let rootPath = root.path + "/"
        return JobRunner(
            processors: processors, capabilities: .none, fallbackFolder: fallback,
            isWritable: { _ in writable },
            trash: { url in
                log.mutate { $0.append(url) }
                guard url.path.hasPrefix(rootPath) else { throw TrashOutsideTestRoot(url: url) }
                try FileManager.default.removeItem(at: url)
            })
    }

    private func req(_ names: [String], _ action: SliceAction) -> JobRequest {
        let urls = names.map { Fixtures.file($0, "source \($0)", in: dir) }
        sources += urls
        return JobRequest(items: urls.map(DroppedItem.init(url:)), action: action)
    }

    private func expectSourcesIntact(sourceLocation: SourceLocation = #_sourceLocation) {
        for url in sources {
            #expect((try? String(contentsOf: url, encoding: .utf8)) == "source \(url.lastPathComponent)",
                    sourceLocation: sourceLocation)
        }
    }

    private func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    // MARK: Brief

    @Test func perItemBatch() async throws {
        let r = try await runner([ok]).run(req(["a.txt", "b.txt", "c.txt"], .convert(.md)), progress: { _ in })
        #expect(r.outputs.map(\.lastPathComponent) == ["a-converted.txt", "b-converted.txt", "c-converted.txt"])
        #expect(r.summary == "Saved 3 files")
        #expect(r.failures.isEmpty && !r.usedFallbackFolder && r.clipboardText == nil)
    }

    @Test func combiningGetsAllInNaturalOrder() async throws {
        _ = try await runner([rec]).run(req(["img10.png", "img2.png", "img1.png"], .convert(.pdf)), progress: { _ in })
        #expect(rec.units.count == 1 && rec.units[0].map(\.url.lastPathComponent) == ["img1.png", "img2.png", "img10.png"])
    }

    @Test func oneFailureContinues() async throws {
        let r = try await runner([failsOn("b.txt", afterWriting: true)])
            .run(req(["a.txt", "b.txt", "c.txt"], .convert(.md)), progress: { _ in })
        #expect(r.failures.count == 1 && r.outputs.count == 2)
        #expect(r.summary == "2 of 3 done · 1 failed")
        #expect(r.failures == [JobFailure(url: sources[1], message: "b.txt is broken")])
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: "b-converted.txt").path))
        #expect(trashLog.allSatisfy { !sources.contains($0) })
        #expect(trashLog.map(\.lastPathComponent) == ["b-converted.txt"])
        #expect(r.undo == .trash(r.outputs))
        expectSourcesIntact()
    }

    @Test func allFailedThrows() async {
        let request = req(["a.txt"], .convert(.md))
        await #expect(throws: OrbitError.unsupported("boom")) {
            try await self.runner([alwaysFails("boom")]).run(request, progress: { _ in })
        }
    }

    @Test func cancelTrashesEverything() async throws {
        let request = req(["a.txt", "b.txt"], .convert(.md))
        await #expect(throws: OrbitError.cancelled) {
            try await self.runner([cancelsOn("b.txt")]).run(request, progress: { _ in })
        }
        #expect(Set(trashLog.map(\.lastPathComponent)) == ["a-converted.txt", "b-converted.txt"])
        #expect(try listing(dir) == ["a.txt", "b.txt"])
        expectSourcesIntact()
    }

    @Test func fallbackFolder() async throws {
        let r = try await runner([ok], writable: false).run(req(["a.txt"], .convert(.md)), progress: { _ in })
        #expect(r.usedFallbackFolder && r.outputs[0].deletingLastPathComponent() == fallback)
    }

    @Test func noProcessor() async {
        let request = req(["a.txt"], .convert(.md))
        await #expect(throws: OrbitError.unsupported("Orbit can't do that with this file.")) {
            try await self.runner([]).run(request, progress: { _ in })
        }
    }

    @Test func progressMonotonicEndsAtOne() async throws {
        let seen = Locked<[Double]>([])
        _ = try await runner([ok]).run(req(["a.txt", "b.txt"], .convert(.md)), progress: { p in seen.mutate { $0.append(p.fraction) } })
        #expect(seen.value == seen.value.sorted() && seen.value.last == 1)
    }

    @Test func summaries() {
        #expect(ResultSummary.text(for: .sizes(before: 2_400_000, after: 610_000), outputCount: 1) == "2.4 MB → 610 KB · 75% smaller")
        #expect(ResultSummary.text(for: .sizes(before: 1_000_000, after: 1_200_000), outputCount: 1) == "1 MB → 1.2 MB · 20% larger")
        #expect(ResultSummary.text(for: .dimensions(from: .init(width: 4032, height: 3024), to: .init(width: 2016, height: 1512)), outputCount: 1) == "4032×3024 → 2016×1512")
        #expect(ResultSummary.text(for: nil, outputCount: 4) == "Saved 4 files")
    }

    @Test func actionText() {
        #expect(SliceAction.convert(.mp4).progressTitle(for: .video) == "Converting to MP4")
        #expect(SliceAction.tool(.crop, nil).progressTitle(for: .video) == "Cropping video")
        #expect(SliceAction.tool(.speed, .speed(2)).outputSuffix == "2x")
        #expect(SliceAction.tool(.speed, .speed(0.5)).outputSuffix == "0.5x")
        #expect(SliceAction.tool(.metadata, .metadataStripAll).outputSuffix == "clean")
        #expect(SliceAction.tool(.metadata, nil).outputSuffix == "edited")
    }

    // MARK: Ruling R11

    @Test func skipsItemsAlreadyInTargetFormat() async throws {
        let seen = Locked<[Double]>([])
        let r = try await runner([rec]).run(req(["a.png", "b.jpg"], .convert(.png)), progress: { p in seen.mutate { $0.append(p.fraction) } })
        #expect(rec.units.map { $0.map(\.url.lastPathComponent) } == [["b.jpg"]])
        #expect(r.outputs.map(\.lastPathComponent) == ["b-converted.txt"])
        #expect(r.failures.isEmpty && r.summary == "Saved 1 file")
        #expect(seen.value == seen.value.sorted() && seen.value.last == 1)
    }

    // MARK: Reservations and cleanup

    @Test func reservationsAvoidDiskAndPendingNames() async throws {
        let existing = Fixtures.file("a-converted.txt", "keep", in: dir)
        let request = req(["a.txt"], .convert(.md))
        let names = Locked<[String]>([])
        let p = FakeProcessor { r, c in
            let src = r.items[0].url
            let first = c.outputURL(src, "converted", "txt")
            let second = c.outputURL(src, "converted", "txt")   // reserved, never written
            names.mutate { $0 = [first.lastPathComponent, second.lastPathComponent] }
            _ = try write(first)
            throw OrbitError.unsupported("late failure")
        }
        await #expect(throws: OrbitError.unsupported("late failure")) {
            try await self.runner([p]).run(request, progress: { _ in })
        }
        #expect(names.value == ["a-converted-2.txt", "a-converted-3.txt"])
        #expect(trashLog.map(\.lastPathComponent) == ["a-converted-2.txt"])
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep")
        #expect(try listing(dir) == ["a-converted.txt", "a.txt"])
        expectSourcesIntact()
    }

    @Test func combinedAndNumberedNames() async throws {
        _ = Fixtures.file("Archive.zip", "old", in: dir)
        let photos = dir.appending(path: "Photos", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
        let reserved = Locked<[URL]>([])
        let p = FakeProcessor { r, c in
            let first = r.items[0].url
            let urls = [c.combinedOutputURL(first, nil, "combined", "pdf"),
                        c.combinedOutputURL(first, "Archive", "", "zip"),
                        c.combinedOutputURL(photos, "Photos", "", "zip")]
                + c.numberedOutputURLs(first, "page", "png", 2)
                + c.numberedOutputURLs(first, "page", "png", 2)
            reserved.mutate { $0 = urls }
            return ProcessorOutput()
        }
        let r = try await runner([p]).run(req(["img2.png", "img1.png"], .convert(.pdf)), progress: { _ in })
        #expect(reserved.value.map(\.lastPathComponent) == [
            "img1-combined.pdf", "Archive-2.zip", "Photos.zip",
            "img1-page-1.png", "img1-page-2.png", "img1-page-1-2.png", "img1-page-2-2.png",
        ])
        #expect(reserved.value.allSatisfy { $0.deletingLastPathComponent().path == dir.path })
        #expect(r.outputs.isEmpty && r.undo == nil && r.summary == "Saved 0 files")
    }

    @Test func reservationsIgnoreCase() async throws {
        let lower = Fixtures.file("x/a.txt", "lower", in: dir)
        let upper = Fixtures.file("y/A.txt", "upper", in: dir)
        let p = FakeProcessor { r, c in
            let urls = r.items.map { c.outputURL($0.url, "converted", "txt") }   // both reserved before either is written
            return ProcessorOutput(outputs: try urls.map { try write($0) })
        }
        let request = JobRequest(items: [lower, upper].map(DroppedItem.init(url:)), action: .tool(.merge, nil))
        let r = try await runner([p], writable: false).run(request, progress: { _ in })
        #expect(Set(r.outputs.map { $0.lastPathComponent.lowercased() }) == ["a-converted.txt", "a-converted-2.txt"])
        #expect(try listing(fallback).count == 2)
    }

    @Test func jobsRunningAtOnceNeverShareAName() async throws {
        let request = req(["a.txt"], .convert(.md))
        let inner = runner([failsOn("a.txt", afterWriting: true)])
        let innerFailed = Locked(false)
        let outer = FakeProcessor { r, c in
            let mine = c.outputURL(r.items[0].url, "converted", "txt")   // reserved, not yet written
            do { _ = try await inner.run(request, progress: { _ in }) } catch {
                innerFailed.mutate { $0 = (error as? OrbitError) == .unsupported("a.txt is broken") }
            }
            return ProcessorOutput(outputs: [try write(mine)])
        }
        let r = try await runner([outer]).run(request, progress: { _ in })
        #expect(innerFailed.value)
        #expect(r.outputs.map(\.lastPathComponent) == ["a-converted.txt"])
        #expect(trashLog.map(\.lastPathComponent) == ["a-converted-2.txt"])
        #expect(try listing(dir) == ["a-converted.txt", "a.txt"])
    }

    @Test func tempDirectoriesAreRemovedAfterTheUnit() async throws {
        let made = Locked<[(URL, Bool)]>([])
        let p = FakeProcessor { r, c in
            let temp = try c.tempDirectory()
            _ = try write(temp.appending(path: "scratch.txt"))
            made.mutate { $0.append((temp, FileManager.default.fileExists(atPath: temp.path))) }
            return try writeConverted(r, c)
        }
        _ = try await runner([p]).run(req(["a.txt"], .convert(.md)), progress: { _ in })
        #expect(made.value.count == 1 && made.value[0].1)
        #expect(!FileManager.default.fileExists(atPath: made.value[0].0.path))
    }

    // MARK: Routing

    @Test func firstCapableProcessorWins() async throws {
        let picky = FakeProcessor(accepts: { _ in false })
        let r = try await runner([picky, ok, rec]).run(req(["a.txt"], .convert(.md)), progress: { _ in })
        #expect(picky.units.isEmpty && ok.units.count == 1 && rec.units.isEmpty && r.outputs.count == 1)
    }

    @Test func unroutableUnitStopsBeforeAnyWork() async throws {
        let onlyA = FakeProcessor(accepts: { named("a.txt", in: $0) && $0.items.count == 1 })
        let request = req(["a.txt", "b.txt"], .convert(.md))
        await #expect(throws: OrbitError.unsupported("Orbit can't do that with this file.")) {
            try await self.runner([onlyA]).run(request, progress: { _ in })
        }
        #expect(onlyA.units.isEmpty)
        #expect(try listing(dir) == ["a.txt", "b.txt"])
    }

    // MARK: Cancellation

    @Test func cancelledTaskStopsBeforeTheNextUnit() async throws {
        let cancelling = FakeProcessor { r, c in
            let out = try writeConverted(r, c)
            withUnsafeCurrentTask { $0?.cancel() }
            return out
        }
        let r = runner([cancelling])
        let request = req(["a.txt", "b.txt"], .convert(.md))
        let job = Task { try await r.run(request, progress: { _ in }) }
        await #expect(throws: OrbitError.cancelled) { try await job.value }
        #expect(cancelling.units.count == 1)
        #expect(trashLog.map(\.lastPathComponent) == ["a-converted.txt"])
        #expect(try listing(dir) == ["a.txt", "b.txt"])
        expectSourcesIntact()
    }

    @Test func cancellationErrorReportsCancelled() async {
        let request = req(["a.txt"], .convert(.md))
        await #expect(throws: OrbitError.cancelled) {
            try await self.runner([FakeProcessor { _, _ in throw CancellationError() }]).run(request, progress: { _ in })
        }
    }

    // MARK: Progress

    @Test func processorProgressIsClampedAndInOrder() async throws {
        let reporting = FakeProcessor { r, c in
            for f in [0.5, 0.2, 7, .nan] { c.progress(f) }
            return try writeConverted(r, c)
        }
        let seen = Locked<[JobProgress]>([])
        _ = try await runner([reporting]).run(req(["a.txt", "b.txt"], .convert(.md)), progress: { p in seen.mutate { $0.append(p) } })
        let fractions = seen.value.map(\.fraction)
        #expect(fractions == fractions.sorted() && fractions.allSatisfy { (0...1).contains($0) } && fractions.last == 1)
        #expect(fractions.contains(0.25) && fractions.contains(0.75))
        #expect(seen.value.first == JobProgress(title: "Converting to MD", fileName: "a.txt", itemIndex: 0, itemCount: 2, fraction: 0))
        #expect(seen.value.last?.fileName == "b.txt" && seen.value.last?.itemIndex == 1)
    }

    @Test func lateProgressIsIgnored() async throws {
        let saved = Locked<JobContext?>(nil)
        let p = FakeProcessor { r, c in saved.mutate { $0 = c }; return try writeConverted(r, c) }
        let count = Locked(0)
        _ = try await runner([p]).run(req(["a.txt"], .convert(.md)), progress: { _ in count.mutate { $0 += 1 } })
        let before = count.value
        saved.value?.progress(0.5)
        #expect(before > 0 && count.value == before)
    }

    // MARK: Results

    @Test func clipboardAndTrashUndo() async throws {
        let copying = FakeProcessor { r, c in
            var o = try writeConverted(r, c)
            o.clipboardText = r.items[0].url.lastPathComponent
            return o
        }
        let r = try await runner([copying]).run(req(["b.txt", "a.txt"], .convert(.md)), progress: { _ in })
        #expect(r.outputs.count == 2 && r.undo == .trash(r.outputs))
        #expect(r.clipboardText == "a.txt\nb.txt")
    }

    @Test func moveBackRecordsAreConcatenated() async throws {
        func moved(_ url: URL) -> FileMove { FileMove(from: url, to: URL(filePath: "/elsewhere/\(url.lastPathComponent)")) }
        let moving = FakeProcessor { r, _ in
            let move = FileMove(from: r.items[0].url, to: URL(filePath: "/elsewhere/\(r.items[0].url.lastPathComponent)"))
            return ProcessorOutput(outputs: [move.to], undo: .moveBack([move]))
        }
        let r = try await runner([moving]).run(req(["a.txt", "b.txt"], .action(.moveTo, nil)), progress: { _ in })
        #expect(r.undo == .moveBack(sources.map(moved)))
    }

    @Test func noOutputsMeansNoUndo() async throws {
        let r = try await runner([FakeProcessor { _, _ in ProcessorOutput(hint: .text("Copied path"), clipboardText: "/x") }])
            .run(req(["a.txt"], .action(.copyPath, .pathStyle(.posix))), progress: { _ in })
        #expect(r.undo == nil && r.outputs.isEmpty && r.clipboardText == "/x" && r.summary == "Copied path")
    }

    @Test func batchSummaries() async throws {
        func hinted(_ hint: SummaryHint) -> FakeProcessor {
            FakeProcessor { r, c in var o = try writeConverted(r, c); o.hint = hint; return o }
        }
        let halves = hinted(.sizes(before: 1_000_000, after: 500_000))
        let shrinks = hinted(.dimensions(from: CGSize(width: 4, height: 4), to: CGSize(width: 2, height: 2)))
        #expect(try await runner([halves]).run(req(["a.txt", "b.txt"], .tool(.compress, nil)), progress: { _ in }).summary
                == "2 MB → 1 MB · 50% smaller")
        #expect(try await runner([shrinks]).run(req(["c.txt", "d.txt"], .tool(.compress, nil)), progress: { _ in }).summary
                == "Saved 2 files")
        #expect(try await runner([shrinks]).run(req(["e.txt"], .tool(.compress, nil)), progress: { _ in }).summary
                == "4×4 → 2×2")
    }

    @Test func summaryCopy() {
        #expect(ResultSummary.text(for: .sizes(before: 1_000_000, after: 1_000_000), outputCount: 1) == "1 MB → 1 MB · same size")
        #expect(ResultSummary.text(for: .count(3, noun: "page"), outputCount: 1) == "3 pages")
        #expect(ResultSummary.text(for: .count(1, noun: "page"), outputCount: 1) == "1 page")
        #expect(ResultSummary.text(for: .text("Copied path"), outputCount: 0) == "Copied path")
        #expect(ResultSummary.text(for: nil, outputCount: 1) == "Saved 1 file")
        #expect(ResultSummary.bytes(999) == "999 bytes")
        #expect(ResultSummary.bytes(999_999) == "1 MB")
        #expect(ResultSummary.bytes(1_500_000_000) == "1.5 GB")
    }

    // MARK: Action text tables

    @Test func combiningRules() {
        let images = [loose("a.png"), loose("b.jpg")]
        let mixed = [loose("a.png"), loose("c.txt")]
        let archives = [loose("a.zip"), loose("b.tar.gz")]
        #expect(SliceAction.convert(.pdf).isCombining(for: images))
        #expect(!SliceAction.convert(.pdf).isCombining(for: [images[0]]))
        #expect(!SliceAction.convert(.pdf).isCombining(for: mixed))
        #expect(!SliceAction.convert(.png).isCombining(for: images))
        for tool in [ToolID.collage, .merge, .join] { #expect(SliceAction.tool(tool, nil).isCombining(for: [images[0]])) }
        #expect(!SliceAction.tool(.compress, nil).isCombining(for: images))
        #expect(SliceAction.action(.archive, .archive(.zip)).isCombining(for: [images[0]]))
        #expect(!SliceAction.action(.copyTo, nil).isCombining(for: images))
        for f in [OutputFormat.zip, .tar, .tgz] {
            #expect(SliceAction.convert(f).isCombining(for: mixed))
            #expect(SliceAction.convert(f).isCombining(for: [DroppedItem(url: dir)]))
            #expect(!SliceAction.convert(f).isCombining(for: archives))
        }
    }

    @Test func progressTitleTable() {
        let rows: [(SliceAction, FileCategory, String)] = [
            (.convert(.tgz), .folder, "Converting to TAR.GZ"),
            (.tool(.removeBackground, nil), .image, "Removing background"),
            (.tool(.addBackground, nil), .image, "Adding background"),
            (.tool(.markup, nil), .image, "Saving markup"),
            (.tool(.adjust, nil), .image, "Adjusting photo"),
            (.tool(.compress, .compress(.tier(.medium))), .pdf, "Compressing"),
            (.tool(.metadata, .metadataStripAll), .image, "Removing metadata"),
            (.tool(.metadata, .metadataStripLocation), .image, "Removing metadata"),
            (.tool(.metadata, nil), .audio, "Saving metadata"),
            (.tool(.readQR, nil), .image, "Reading QR code"),
            (.tool(.collage, nil), .image, "Making collage"),
            (.tool(.trim, nil), .video, "Trimming video"),
            (.tool(.trim, nil), .audio, "Trimming audio"),
            (.tool(.crop, nil), .video, "Cropping video"),
            (.tool(.speed, .speed(2)), .video, "Changing speed"),
            (.tool(.split, nil), .video, "Splitting video"),
            (.tool(.split, nil), .audio, "Splitting audio"),
            (.tool(.split, .pdfSplitEveryPage), .pdf, "Splitting PDF"),
            (.tool(.snapshot, nil), .video, "Saving snapshot"),
            (.tool(.mute, nil), .video, "Muting video"),
            (.tool(.removeMetadata, nil), .video, "Removing metadata"),
            (.tool(.join, nil), .video, "Joining videos"),
            (.tool(.normalize, nil), .audio, "Normalizing audio"),
            (.tool(.bleep, nil), .audio, "Bleeping audio"),
            (.tool(.channels, .channels(.swap)), .audio, "Changing channels"),
            (.tool(.merge, nil), .pdf, "Merging PDFs"),
            (.tool(.organize, nil), .pdf, "Organizing pages"),
            (.tool(.redact, nil), .pdf, "Redacting"),
            (.tool(.extract, nil), .archive, "Extracting"),
            (.action(.copyTo, nil), .other, "Copying"),
            (.action(.moveTo, nil), .other, "Moving"),
            (.action(.archive, .archive(.zip)), .other, "Archiving"),
            (.action(.copyPath, .pathStyle(.uri)), .other, "Copying path"),
        ]
        for (action, category, title) in rows {
            #expect(action.progressTitle(for: category) == title, "\(action) on \(category)")
        }
    }

    @Test func outputSuffixTable() {
        let rows: [(SliceAction, String)] = [
            (.convert(.png), "converted"),
            (.tool(.removeBackground, nil), "nobg"),
            (.tool(.addBackground, nil), "bg"),
            (.tool(.markup, nil), "edited"),
            (.tool(.adjust, nil), "adjusted"),
            (.tool(.compress, .bitrate(128)), "compressed"),
            (.tool(.metadata, .metadataStripAll), "clean"),
            (.tool(.metadata, .metadataStripLocation), "clean"),
            (.tool(.metadata, nil), "edited"),
            (.tool(.collage, nil), "collage"),
            (.tool(.trim, nil), "trimmed"),
            (.tool(.crop, nil), "cropped"),
            (.tool(.speed, .speed(0.25)), "0.25x"),
            (.tool(.speed, .speed(1.5)), "1.5x"),
            (.tool(.speed, .speed(4)), "4x"),
            (.tool(.split, nil), "part"),
            (.tool(.snapshot, nil), "snapshot"),
            (.tool(.mute, nil), "muted"),
            (.tool(.removeMetadata, nil), "clean"),
            (.tool(.join, nil), "joined"),
            (.tool(.normalize, nil), "normalized"),
            (.tool(.bleep, nil), "bleeped"),
            (.tool(.channels, .channels(.toMono)), "mono"),
            (.tool(.channels, .channels(.toStereo)), "stereo"),
            (.tool(.channels, .channels(.swap)), "swapped"),
            (.tool(.merge, nil), "merged"),
            (.tool(.organize, nil), "organized"),
            (.tool(.redact, nil), "redacted"),
            (.tool(.readQR, nil), ""),
            (.tool(.extract, nil), ""),
            (.action(.archive, .archive(.zip)), ""),
            (.action(.copyTo, nil), ""),
        ]
        for (action, suffix) in rows { #expect(action.outputSuffix == suffix, "\(action)") }
    }

    // MARK: Requests and parameters

    @Test func jobOptionsFromSettings() {
        // Read-only: setting a SettingsStore property would leave a plist in ~/Library/Preferences.
        let s = SettingsStore(defaults: UserDefaults(suiteName: "orbit-test-\(UUID())")!)
        #expect(s.jobOptions == JobOptions())
        #expect(JobOptions() == JobOptions(jpegQuality: 0.85, heicQuality: 0.8, webpQuality: 0.8, avifQuality: 0.7, pdfDPI: 300))
        let r = JobRequest(items: [], action: .convert(.png))
        #expect(r.parameters == .none && r.options == JobOptions())
    }

    @Test func fixturesFindHomebrewFFmpegFirst() {
        #expect(Fixtures.hasFFmpeg == (Fixtures.ffmpeg != nil))
        if let ffmpeg = Fixtures.ffmpeg { #expect(Fixtures.caps.ffmpeg == ffmpeg) }
    }

    @Test func toolParameterDefaults() {
        let a = AdjustSettings()
        #expect(!a.auto && a.exposure == 0 && a.contrast == 1 && a.saturation == 1 && a.warmth == 0)
        #expect(!a.blackAndWhite && a.quarterTurns == 0 && !a.flipHorizontal && !a.flipVertical)
        #expect(ToolParameters.markup(MarkupDocument()) == .markup(MarkupDocument(elements: [], crop: nil, resize: nil)))
        #expect(ToolParameters.none != .time(1))
    }
}
