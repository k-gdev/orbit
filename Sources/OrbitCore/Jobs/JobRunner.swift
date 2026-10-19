import Foundation

/// Runs a `JobRequest`: splits it into units, routes each unit to a processor, hands out reserved
/// output names, reports progress, cleans up after failures and cancellation, and builds the result.
///
/// Safety: cleanup only ever trashes URLs that this job reserved through its `JobContext` and that
/// exist at cleanup time. A reserved URL never existed when it was handed out, and a source item
/// is never trashed.
public final class JobRunner: Sendable {
    static let unsupportedMessage = "Orbit can't do that with this file."

    private let processors: [any Processor]
    private let capabilities: Capabilities
    private let fallbackFolder: URL
    private let isWritable: @Sendable (URL) -> Bool
    private let trash: @Sendable (URL) throws -> Void

    public init(
        processors: [any Processor],
        capabilities: Capabilities,
        fallbackFolder: URL = OutputLocator.fallbackFolder,
        isWritable: @escaping @Sendable (URL) -> Bool = { FileManager.default.isWritableFile(atPath: $0.path) },
        trash: @escaping @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) {
        self.processors = processors
        self.capabilities = capabilities
        self.fallbackFolder = fallbackFolder
        self.isWritable = isWritable
        self.trash = trash
    }

    public func run(_ request: JobRequest, progress: @escaping @Sendable (JobProgress) -> Void) async throws -> JobResult {
        let items = Self.naturalOrder(request.items)
        guard !items.isEmpty else { throw OrbitError.unsupported(Self.unsupportedMessage) }
        let action = request.action
        let combining = action.isCombining(for: items)
        let units = (combining ? [items] : items.map { [$0] }).map {
            JobRequest(items: $0, action: action, parameters: request.parameters, options: request.options)
        }

        let ledger = JobLedger(sources: items.map(\.url), trash: trash)
        let reporter = ProgressReporter(unitCount: units.count, sink: progress)
        defer {
            reporter.close()
            ledger.close()
        }
        func cancelled() -> any Error {
            let stuck = ledger.discardAll()
            // A partial file Orbit couldn't trash (no Trash on that volume) is named, never left silently.
            guard stuck.isEmpty else { return OrbitError.unsupported("Cancelled · \(Self.stuckText(stuck))") }
            return OrbitError.cancelled
        }

        var done: [ProcessorOutput] = []
        var failures: [JobFailure] = []
        var firstError: (any Error)?
        var usedFallback = false
        var stuckPartials: [URL] = []
        func recordFailure(_ error: any Error, unit: JobRequest, title: String) {
            let first = unit.items[0]
            Log.error("\(title) failed for \(first.url.lastPathComponent): \(error.localizedDescription)")
            failures.append(JobFailure(url: first.url, message: error.localizedDescription))
            if firstError == nil { firstError = error }
        }

        for (index, unit) in units.enumerated() {
            let first = unit.items[0]
            let title = action.progressTitle(for: first.category)
            let fileName = first.url.lastPathComponent
            if Task.isCancelled { throw cancelled() }
            if !combining, Self.isAlreadyInTargetFormat(unit) {
                // Ruling R11: already in the target format. Counts as done; nothing is written.
                reporter.finish(index, title: title, fileName: fileName)
                continue
            }
            guard let processor = processors.first(where: { $0.canHandle(unit) }) else {
                // Ruling R20: no processor for this unit is a unit failure; the batch carries on.
                recordFailure(OrbitError.unsupported(Self.unsupportedMessage), unit: unit, title: title)
                reporter.finish(index, title: title, fileName: fileName)
                continue
            }
            reporter.start(index, title: title, fileName: fileName)
            let folder = OutputLocator.folder(for: first.url, fallback: fallbackFolder, isWritable: isWritable)
            let context = makeContext(unit: index, folder: folder.url, options: request.options,
                                      ledger: ledger, reporter: reporter)
            do {
                let output = try await processor.run(unit, context: context)
                ledger.removeTempDirectories(unit: index)
                done.append(output)
                if folder.usedFallback { usedFallback = true }
            } catch {
                ledger.removeTempDirectories(unit: index)
                let cancelling = Self.isCancellation(error) || Task.isCancelled
                // Copy/Move To roll back themselves; a rollback that left files behind names them,
                // so it is reported even when the job was cancelled.
                if cancelling && !Self.isIncompleteRollback(error, action: action) { throw cancelled() }
                let stuck = ledger.discard(unit: index)
                stuckPartials += stuck
                let reported = stuck.isEmpty ? error
                    : OrbitError.unsupported("\(error.localizedDescription) · \(Self.stuckText(stuck))")
                recordFailure(reported, unit: unit, title: title)
            }
            reporter.finish(index, title: title, fileName: fileName)
        }
        // Every unit has finished here, so a cancel that arrived during the last one is too late to
        // undo anything: the finished work is reported (with its Undo) rather than dropped.
        if let firstError, failures.count == units.count { throw firstError }

        let outputs = done.flatMap(\.outputs)
        let texts = done.compactMap(\.clipboardText)
        return JobResult(
            outputs: outputs,
            summary: Self.summary(unitCount: units.count, failureCount: failures.count, done: done,
                                  outputCount: outputs.count, stuck: stuckPartials),
            undo: Self.undo(action: action, done: done, outputs: outputs, ledger: ledger),
            usedFallbackFolder: usedFallback,
            clipboardText: texts.isEmpty ? nil : texts.joined(separator: "\n"),
            failures: failures)
    }

    private func makeContext(unit: Int, folder: URL, options: JobOptions, ledger: JobLedger,
                             reporter: ProgressReporter) -> JobContext {
        JobContext(
            options: options,
            capabilities: capabilities,
            progress: { reporter.update(unit, $0) },
            outputURL: { source, suffix, ext in
                ledger.reserve(unit: unit) { taken in
                    [OutputNamer.outputURL(for: source, suffix: suffix, ext: ext, in: folder, exists: taken)]
                }[0]
            },
            numberedOutputURLs: { source, suffix, ext, count in
                // The names within one call can't collide: each base ends in its own "-<i>".
                ledger.reserve(unit: unit) { taken in
                    OutputNamer.numberedURLs(for: source, suffix: suffix, ext: ext, count: count, in: folder, exists: taken)
                }
            },
            combinedOutputURL: { first, base, suffix, ext in
                let name = (base ?? OutputNamer.stem(of: first)) + (suffix.isEmpty ? "" : "-\(suffix)")
                return ledger.reserve(unit: unit) { taken in
                    [OutputNamer.uniqueURL(in: folder, base: name, ext: ext, exists: taken)]
                }[0]
            },
            claimDestination: { destination, base, ext in ledger.claim(in: destination, base: base, ext: ext) },
            tempDirectory: { try ledger.makeTempDirectory(unit: unit) })
    }

    // MARK: Rules

    /// Same order as `naturalSorted(_:)`: Finder's order, by file name.
    private static func naturalOrder(_ items: [DroppedItem]) -> [DroppedItem] {
        items.sorted { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }
    }

    /// Ruling R11: a per-item convert whose item is already in the target format is skipped.
    private static func isAlreadyInTargetFormat(_ unit: JobRequest) -> Bool {
        guard case .convert(let format) = unit.action, unit.items.count == 1 else { return false }
        return unit.items[0].formatKey == format.rawValue
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        (error as? OrbitError) == .cancelled || error is CancellationError
    }

    /// Copy/Move To's own error naming files it couldn't put back (FileActions.rollbackError).
    private static func isIncompleteRollback(_ error: any Error, action: SliceAction) -> Bool {
        guard case .unsupported? = error as? OrbitError else { return false }
        switch action {
        case .action(.copyTo, _), .action(.moveTo, _): return true
        default: return false
        }
    }

    /// "couldn't remove partial file a.mp4" / "couldn't remove partial files a.mp4, b.mp4".
    private static func stuckText(_ urls: [URL]) -> String {
        let names = urls.map(\.lastPathComponent).joined(separator: ", ")
        return "couldn't remove partial file\(urls.count == 1 ? "" : "s") \(names)"
    }

    private static func summary(unitCount: Int, failureCount: Int, done: [ProcessorOutput], outputCount: Int,
                                stuck: [URL]) -> String {
        if failureCount > 0 {
            let head = "\(unitCount - failureCount) of \(unitCount) done · \(failureCount) failed"
            return stuck.isEmpty ? head : "\(head) · \(stuckText(stuck))"
        }
        if unitCount == 1 { return ResultSummary.text(for: done.first?.hint, outputCount: outputCount) }
        if let sizes = summedSizes(done) { return ResultSummary.text(for: sizes, outputCount: outputCount) }
        return ResultSummary.text(for: nil, outputCount: outputCount)
    }

    /// The before/after totals when every processed unit reported sizes.
    private static func summedSizes(_ done: [ProcessorOutput]) -> SummaryHint? {
        guard !done.isEmpty else { return nil }
        var before: Int64 = 0
        var after: Int64 = 0
        for output in done {
            guard case .sizes(let b, let a)? = output.hint else { return nil }
            before += b
            after += a
        }
        return .sizes(before: before, after: after)
    }

    /// Move-back records are concatenated; otherwise undo trashes the outputs (never a source).
    private static func undo(action: SliceAction, done: [ProcessorOutput], outputs: [URL], ledger: JobLedger) -> UndoRecord? {
        var moves: [FileMove] = []
        var movedSomething = false
        for output in done {
            if case .moveBack(let m)? = output.undo {
                moves += m
                movedSomething = true
            }
        }
        if movedSomething { return .moveBack(moves) }
        // Move To's outputs are the user's own files in their new place (R18): never offer to trash them.
        if case .action(.moveTo, _) = action { return nil }
        let trashable = outputs.filter { !ledger.isSource($0) }
        return trashable.isEmpty ? nil : .trash(trashable)
    }
}

// MARK: - Reservation and cleanup state

/// How two URLs are compared for reservations. Case-insensitive, like default APFS volumes;
/// Swift string comparison already treats NFC and NFD forms as equal.
private func reservationKey(_ url: URL) -> String {
    url.standardizedFileURL.path.lowercased()
}

/// True for anything at the path, including a symbolic link whose target is missing.
private func existsOnDisk(_ url: URL) -> Bool {
    let fm = FileManager.default
    return fm.fileExists(atPath: url.path) || (try? fm.attributesOfItem(atPath: url.path)) != nil
}

/// Names held by every job running in this process: output reservations and claimed destinations
/// (R19). Two jobs never get the same name, so one job's moved or copied file can't land on another
/// job's pending reservation and then be trashed by its cleanup. A job releases its names when it
/// ends; by then its files exist on disk and the disk check covers them.
private final class ActiveReservations: @unchecked Sendable {
    static let shared = ActiveReservations()
    private let lock = NSLock()
    private var keys: Set<String> = []

    /// Runs `make` with a "taken" test (on disk or reserved), then reserves what it returns, atomically.
    func reserve(_ make: ((URL) -> Bool) -> [URL]) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        let urls = make { self.keys.contains(reservationKey($0)) || existsOnDisk($0) }
        for url in urls { keys.insert(reservationKey(url)) }
        return urls
    }

    func release(_ urls: [URL]) {
        lock.lock(); defer { lock.unlock() }
        for url in urls { keys.remove(reservationKey(url)) }
    }
}

/// One job's reserved URLs and scratch folders. `reserved` is the only list cleanup ever trashes
/// from; `claimed` destinations are held against other jobs but never cleaned up.
private final class JobLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var reserved: [(url: URL, unit: Int)] = []
    private var claimed: [URL] = []
    private var temps: [(url: URL, unit: Int)] = []
    private let sourceKeys: Set<String>
    private let trash: @Sendable (URL) throws -> Void

    init(sources: [URL], trash: @escaping @Sendable (URL) throws -> Void) {
        sourceKeys = Set(sources.map(reservationKey))
        self.trash = trash
    }

    func reserve(unit: Int, _ make: ((URL) -> Bool) -> [URL]) -> [URL] {
        let urls = ActiveReservations.shared.reserve(make)
        lock.lock(); defer { lock.unlock() }
        reserved += urls.map { ($0, unit) }
        return urls
    }

    /// A unique `base[.ext]` in `folder`, held for the job but never trashed by its cleanup (R19).
    func claim(in folder: URL, base: String, ext: String) -> URL {
        let url = ActiveReservations.shared.reserve { taken in
            [OutputNamer.uniqueURL(in: folder, base: base, ext: ext, exists: taken)]
        }[0]
        lock.lock(); defer { lock.unlock() }
        claimed.append(url)
        return url
    }

    func makeTempDirectory(unit: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "Orbit/job-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        lock.lock(); defer { lock.unlock() }
        temps.append((url, unit))
        return url
    }

    /// Removes the scratch folders of one unit, or of the whole job when `unit` is nil.
    func removeTempDirectories(unit: Int? = nil) {
        lock.lock()
        let doomed = temps.filter { unit == nil || $0.unit == unit }.map(\.url)
        temps.removeAll { unit == nil || $0.unit == unit }
        lock.unlock()
        for url in doomed {
            do { try FileManager.default.removeItem(at: url) } catch {
                Log.error("could not remove scratch folder \(url.path): \(error.localizedDescription)")
            }
        }
    }

    /// Trashes this unit's reserved URLs that exist now; returns the ones that couldn't be trashed.
    @discardableResult
    func discard(unit: Int) -> [URL] { trashExisting(reservedURLs(unit: unit)) }

    /// Trashes every reserved URL of the job that exists now; returns the ones that couldn't be trashed.
    @discardableResult
    func discardAll() -> [URL] { trashExisting(reservedURLs(unit: nil)) }

    func isSource(_ url: URL) -> Bool { sourceKeys.contains(reservationKey(url)) }

    /// Ends the job: removes its scratch folders and releases its names for other jobs.
    func close() {
        removeTempDirectories()
        lock.lock()
        let held = reserved.map(\.url) + claimed
        lock.unlock()
        ActiveReservations.shared.release(held)
    }

    private func reservedURLs(unit: Int?) -> [URL] {
        lock.lock(); defer { lock.unlock() }
        return reserved.filter { unit == nil || $0.unit == unit }.map(\.url)
    }

    private func trashExisting(_ urls: [URL]) -> [URL] {
        var stuck: [URL] = []
        for url in urls where !isSource(url) && existsOnDisk(url) {
            do { try trash(url) } catch {
                Log.error("could not trash \(url.path): \(error.localizedDescription)")
                stuck.append(url)
            }
        }
        return stuck
    }
}

// MARK: - Progress

/// Turns unit progress into whole-job progress that never goes backwards, and drops reports from
/// a unit that has ended. The sink is called under a lock, so it must not call back into the job.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private let unitCount: Int
    private let sink: @Sendable (JobProgress) -> Void
    private var last = 0.0
    private var open: (unit: Int, title: String, fileName: String)?
    private var closed = false

    init(unitCount: Int, sink: @escaping @Sendable (JobProgress) -> Void) {
        self.unitCount = max(unitCount, 1)
        self.sink = sink
    }

    func start(_ unit: Int, title: String, fileName: String) {
        lock.lock(); defer { lock.unlock() }
        open = (unit, title, fileName)
        emit(unit, title, fileName, Double(unit) / Double(unitCount))
    }

    func update(_ unit: Int, _ fraction: Double) {
        lock.lock(); defer { lock.unlock() }
        guard let current = open, current.unit == unit else { return }
        let clamped = fraction.isNaN ? 0 : min(max(fraction, 0), 1)
        emit(unit, current.title, current.fileName, (Double(unit) + clamped) / Double(unitCount))
    }

    func finish(_ unit: Int, title: String, fileName: String) {
        lock.lock(); defer { lock.unlock() }
        open = nil
        emit(unit, title, fileName, unit + 1 >= unitCount ? 1 : Double(unit + 1) / Double(unitCount))
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        open = nil
        closed = true
    }

    private func emit(_ unit: Int, _ title: String, _ fileName: String, _ fraction: Double) {
        guard !closed else { return }
        last = max(last, fraction)
        sink(JobProgress(title: title, fileName: fileName, itemIndex: unit, itemCount: unitCount, fraction: last))
    }
}
