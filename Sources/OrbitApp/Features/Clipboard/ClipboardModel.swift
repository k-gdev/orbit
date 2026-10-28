import AppKit
import Combine
import ImageIO
import OrbitCore

/// The clipboard history the panel, the popup and the settings page all show: `ClipboardHistory` plus
/// the store it persists to. Every change is written to disk straight away (the index is small), and
/// the blob files of removed or evicted entries are deleted with them.
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

    /// The clock, replaced by a fixed one in snapshots so relative times are stable.
    var now: () -> Date = { Date() }

    private var fixtureThumbnails: [UUID: NSImage] = [:]
    private let thumbnailCache = NSCache<NSUUID, NSImage>()

    init(settings: ClipboardSettings, store: ClipboardStore) {
        self.settings = settings
        self.store = store
    }

    /// A model over a fixed list of entries and in-memory thumbnails; it never reads or writes a file.
    init(fixtureItems: [ClipboardItem], thumbnails: [UUID: NSImage], settings: ClipboardSettings, now: Date) {
        self.settings = settings
        self.store = nil
        self.history = ClipboardHistory(items: fixtureItems)
        self.fixtureThumbnails = thumbnails
        self.now = { now }
        self.isLoaded = true
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
        let previous = ingestTail
        ingestTail = Task { [weak self] in
            await previous?.value
            if Task.isCancelled { return }
            let outcome = await Task.detached(priority: .utility) { copy.makeCapture(maxItemBytes: maxItemBytes) }.value
            if Task.isCancelled { return }
            switch outcome {
            case .skipped(let reason): Log.info("clipboard: skipped a copy (\(reason))")
            case .capture(let capture): await self?.add(capture)
            }
        }
    }

    /// Stops handling copies that are still being processed (the feature was turned off).
    func cancelIngest() {
        ingestTail?.cancel()
        ingestTail = nil
    }

    /// Adds a prepared copy. The same content again moves its entry to the top (no second file is written).
    private func add(_ capture: ClipboardCapture) async {
        guard !persistenceBlocked, settings.limits.allowsItem(ofSize: capture.payload.count) else { return }
        var item = capture.makeItem(payloadFile: nil)   // the hash was computed off the main thread
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
            // A blob with no entry is swept at the next launch if the copy is dropped here.
            if Task.isCancelled { store?.deletePayloads([name]); return }
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
        store?.deletePayloads(evicted.compactMap(\.payloadFile))
        save()
    }

    func togglePin(_ id: UUID) {
        guard history.togglePin(id: id) != nil else { return }
        save()
    }

    func remove(_ id: UUID) {
        guard let removed = history.remove(id: id) else { return }
        store?.deletePayloads(removed.payloadFile.map { [$0] } ?? [])
        save()
    }

    /// Clears the history; pinned entries stay unless `keepPinned` is false.
    func clear(keepPinned: Bool = true) {
        loadIfNeeded()
        let removed = history.clear(keepPinned: keepPinned)
        guard !removed.isEmpty else { return }
        store?.deletePayloads(removed.compactMap(\.payloadFile))
        save()
    }

    /// An entry was just pasted or copied again: it goes to the top.
    func markUsed(_ id: UUID) {
        guard history.moveToTop(id: id, date: now()) else { return }
        save()
    }

    func payload(for item: ClipboardItem) -> Data? {
        item.payloadFile.flatMap { store?.readPayload(named: $0) }
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
