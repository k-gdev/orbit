import AppKit
import Combine
import ImageIO
import OrbitCore

/// The clipboard history the panel, the popup and the settings page all show: `ClipboardHistory` plus
/// the store it persists to. Every change is written to disk straight away (the index is small), and
/// the blob files of removed or evicted entries are deleted with them.
///
/// Copied passwords (`ClipboardItem.concealed`, kept only while `settings.recordPasswords` is on) are the
/// exception: their content lives in `concealedPayloads` in memory, the store never writes them, and they are
/// gone when Orbit quits or the setting is turned off.
///
/// Nothing is read from disk until `loadIfNeeded()`. A fixture
/// model (`store == nil`) holds a fixed list and never touches disk, for snapshots.
@MainActor
final class ClipboardModel: ObservableObject {
    let settings: ClipboardSettings
    private let store: ClipboardStore?

    @Published private(set) var history = ClipboardHistory()
    private var isLoaded = false
    /// Set when the on-disk index was unreadable and could not be kept: nothing is written, so that
    /// file (and every blob) stays exactly as it was.
    private var persistenceBlocked = false
    /// The copy being processed, so the next one waits for it (history keeps copy order).
    private var ingestTail: Task<Void, Never>?
    /// Bumped by `cancelIngest()`. Each queued copy remembers the generation it arrived in and writes or adds
    /// nothing once that is over: cancelling the tail task alone would leave the older copies it waits on
    /// running.
    private var ingestGeneration = 0

    /// The clock, replaced by a fixed one in snapshots so relative times are stable.
    var now: () -> Date = { Date() }

    private var fixtureThumbnails: [UUID: NSImage] = [:]
    private let thumbnailCache = NSCache<NSUUID, NSImage>()
    /// The content of the copied passwords, by entry id. Memory only.
    private var concealedPayloads: [UUID: Data] = [:]
    /// What was last found out about each files entry's files (see `refreshFileStatus`). Absent: not checked.
    @Published private(set) var fileStatuses: [UUID: ClipboardFileStatus] = [:]
    private var passwordsSubscription: AnyCancellable?

    init(settings: ClipboardSettings, store: ClipboardStore) {
        self.settings = settings
        self.store = store
        watchPasswordSetting()
    }

    /// A model over a fixed list of entries and in-memory thumbnails; it never reads or writes a file.
    init(fixtureItems: [ClipboardItem], thumbnails: [UUID: NSImage], settings: ClipboardSettings, now: Date) {
        self.settings = settings
        self.store = nil
        self.history = ClipboardHistory(items: fixtureItems)
        self.fixtureThumbnails = thumbnails
        self.now = { now }
        self.isLoaded = true
        watchPasswordSetting()
    }

    /// Turning "Keep copied passwords" off removes the ones already kept, at once.
    private func watchPasswordSetting() {
        passwordsSubscription = settings.$recordPasswords
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] keep in
                guard !keep else { return }
                MainActor.assumeIsolated { self?.removeConcealed() }
            }
    }

    // MARK: Loading

    /// Reads the index once: entries whose content file is gone are dropped, orphaned content files
    /// are swept (only when the index itself was fine), and the limits are applied.
    func loadIfNeeded() {
        guard !isLoaded else { return }
        isLoaded = true
        guard let store else { return }
        let result = store.load()
        let usable = store.itemsWithPayloads(result.items)
        history = ClipboardHistory(items: usable)
        if result.indexWasUnreadable {
            if let backup = result.corruptBackup {
                Log.error("clipboard: the history index was unreadable; kept as \(backup.lastPathComponent)")
            } else {
                // It could not be set aside or copied either, so it must not be overwritten: run this
                // session without saving, and leave every file alone.
                persistenceBlocked = true
                Log.error("clipboard: the history index was unreadable and could not be kept; history is not saved this session")
            }
        }
        // Orphaned blobs are swept only after a clean read (never after an unreadable or partly read index).
        store.sweepOrphans(after: result, keeping: Set(usable.compactMap(\.payloadFile)))
        // Exported images (drag-outs, Open in Preview) whose entry is gone, or that are over a day old.
        if !result.indexWasUnreadable { ClipboardExportFolder.standard.sweep(keeping: Set(usable.map(\.id))) }
        if usable.count != result.items.count || result.droppedCount > 0 { save() }
        enforceLimits()
    }

    /// Gives back what can be rebuilt (decoded thumbnails) when the feature is turned off. The history
    /// itself stays in memory so the Settings page keeps showing the right numbers; it is small.
    func trimMemory() {
        thumbnailCache.removeAllObjects()
    }

    // MARK: Changes

    /// Takes a copy the watcher just read. The heavy part (decoding, RTF parsing, converting an image to
    /// PNG, hashing, writing the blob file) runs on background queues; only the cheap bookkeeping (the
    /// duplicate check, inserting into the history, saving the small index) happens here on the main
    /// thread. Copies are handled one at a time in the order they arrived, so history order is kept.
    func ingest(_ copy: RawPasteboardCopy) {
        loadIfNeeded()
        guard !persistenceBlocked else { return }
        let maxItemBytes = settings.limits.maxItemBytes
        let generation = ingestGeneration
        let previous = ingestTail
        ingestTail = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.ingestGeneration == generation else { return }
            let outcome = await Task.detached(priority: .utility) { copy.makeCapture(maxItemBytes: maxItemBytes) }.value
            guard !Task.isCancelled, self?.ingestGeneration == generation else { return }
            switch outcome {
            case .skipped(let reason): Log.info("clipboard: skipped a copy (\(reason))")
            case .capture(let capture): await self?.add(capture, generation: generation)
            }
        }
    }

    /// Stops handling copies that are still being processed (the feature was turned off): none of them
    /// writes a blob or adds an entry from now on, including the older ones the newest is waiting for.
    func cancelIngest() {
        ingestGeneration &+= 1
        ingestTail?.cancel()
        ingestTail = nil
    }

    /// Adds a prepared copy that arrived in `generation`. The same content again moves its entry to the top
    /// (no second file is written).
    private func add(_ capture: ClipboardCapture, generation: Int) async {
        guard generation == ingestGeneration, !persistenceBlocked,
              settings.limits.allowsItem(ofSize: capture.payload.count) else { return }
        // The setting may have been turned off while the copy was being prepared.
        guard !capture.concealed || settings.recordPasswords else { return }
        var item = capture.makeItem(payloadFile: nil)   // the hash was computed off the main thread
        if capture.concealed {
            // A copied password: its content stays in memory, no blob is written, the index never lists it.
            if !history.contains(contentHash: item.contentHash) { concealedPayloads[item.id] = capture.payload }
            history.add(item)
            enforceLimits()
            return
        }
        if !history.contains(contentHash: item.contentHash) {
            let name = ClipboardStore.newPayloadName(for: capture.kind)
            let payload = capture.payload
            let store = self.store
            do {
                try await Task.detached(priority: .utility) { try store?.writePayload(payload, named: name) }.value
            } catch {
                Log.error("clipboard: could not store a copy: \(error)")
                return
            }
            // Cancelled while the blob was written: remove it again (anything left is swept at the next launch).
            if Task.isCancelled || generation != ingestGeneration { store?.deletePayloads([name]); return }
            item.payloadFile = name
        }
        if case .movedToTop(let unused?) = history.add(item) {
            store?.deletePayloads([unused])
        }
        enforceLimits()
        save()
    }

    /// Applies the size, count and age limits; the evicted entries' files go with them.
    func enforceLimits() {
        let evicted = history.enforce(limits: settings.limits, now: now())
        guard !evicted.isEmpty else { return }
        forget(evicted)
        // A password leaving changes nothing on disk.
        if evicted.contains(where: { !$0.concealed }) { save() }
    }

    /// Releases what removed entries held: blob files, exported images, and the memory of copied passwords.
    private func forget(_ items: [ClipboardItem]) {
        store?.deletePayloads(items.compactMap(\.payloadFile))
        if store != nil { ClipboardExportFolder.standard.remove(items.filter { $0.kind == .image }.map(\.id)) }
        for item in items where item.concealed { concealedPayloads[item.id] = nil }
        for item in items { fileStatuses[item.id] = nil }
    }

    func togglePin(_ id: UUID) {
        guard history.togglePin(id: id) != nil else { return }
        save()
    }

    func remove(_ id: UUID) {
        guard let removed = history.remove(id: id) else { return }
        forget([removed])
        if !removed.concealed { save() }
    }

    /// Clears the history; pinned entries stay unless `keepPinned` is false.
    func clear(keepPinned: Bool = true) {
        loadIfNeeded()
        let removed = history.clear(keepPinned: keepPinned)
        guard !removed.isEmpty else { return }
        forget(removed)
        save()
    }

    /// Drops every copied password (the setting was turned off, or the feature was). Nothing on disk changes.
    func removeConcealed() {
        forget(history.removeConcealed())
    }

    /// An entry was just pasted or copied again: it goes to the top.
    func markUsed(_ id: UUID) {
        guard history.moveToTop(id: id, date: now()) else { return }
        save()
    }

    func payload(for item: ClipboardItem) -> Data? {
        if item.concealed { return concealedPayloads[item.id] }
        return item.payloadFile.flatMap { store?.readPayload(named: $0) }
    }

    // MARK: Files and images as real files

    /// The files a files entry points at (none for other kinds, or when the list cannot be read).
    func filePaths(of item: ClipboardItem) -> [String] {
        guard item.kind == .files, let payload = payload(for: item) else { return [] }
        return ClipboardPayload.filePaths(from: payload)
    }

    /// Checks now which of the entry's files still exist and remembers it for the row. This stats each
    /// file, so it is for the moment a row or its menu appears, not for polling. Nil (nothing remembered)
    /// for other kinds and for a list that cannot be read.
    @discardableResult
    func checkFiles(of item: ClipboardItem) -> ClipboardFileStatus? {
        let paths = filePaths(of: item)
        guard !paths.isEmpty else { return nil }
        let status = ClipboardFileStatus(paths: paths)
        if fileStatuses[item.id] != status { fileStatuses[item.id] = status }
        return status
    }

    /// `checkFiles(of:)` for a row that has just appeared, with the stat calls off the main thread (a
    /// file on a disconnected volume can take a while to answer).
    func refreshFileStatus(of item: ClipboardItem) async {
        let paths = filePaths(of: item)
        guard !paths.isEmpty else { return }
        let status = await Task.detached(priority: .utility) { ClipboardFileStatus(paths: paths) }.value
        if fileStatuses[item.id] != status { fileStatuses[item.id] = status }
    }

    /// A PNG file for an image entry, for Preview or a drag. Nil when its content is gone.
    func exportedImageURL(for item: ClipboardItem) -> URL? {
        guard item.kind == .image, let png = payload(for: item) else { return nil }
        do { return try ClipboardExportFolder.standard.writeImage(png, for: item.id, now: now()) } catch {
            Log.error("clipboard: could not export an image: \(error)")
            return nil
        }
    }

    private func save() {
        guard let store, !persistenceBlocked else { return }
        do { try store.save(history.items) } catch { Log.error("clipboard: could not save the history: \(error)") }
    }

    // MARK: Thumbnails

    /// A thumbnail already in memory (fixtures, or one loaded before), without any work.
    func cachedThumbnail(for item: ClipboardItem) -> NSImage? {
        fixtureThumbnails[item.id] ?? thumbnailCache.object(forKey: item.id as NSUUID)
    }

    /// A small preview of an image entry, decoded off the main thread from the stored PNG.
    func thumbnail(for item: ClipboardItem) async -> NSImage? {
        if let cached = cachedThumbnail(for: item) { return cached }
        guard item.kind == .image, let name = item.payloadFile, let url = store?.payloadURL(named: name) else { return nil }
        let cgImage = await Task.detached(priority: .utility) { Self.makeThumbnail(at: url, maxPixels: 160) }.value
        guard let cgImage else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        thumbnailCache.setObject(image, forKey: item.id as NSUUID)
        return image
    }

    nonisolated private static func makeThumbnail(at url: URL, maxPixels: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
