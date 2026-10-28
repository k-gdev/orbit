import AppKit
import Combine
import OrbitCore
import UniformTypeIdentifiers

/// What is on the shelf, as the floating shelf and the menu bar tab show it, persisted through a
/// `ShelfStore` after every change. The shelf holds references to the original files: nothing here moves,
/// copies or deletes a file. Main actor only.
///
/// Nothing in here touches the file system on the main thread: the saved list is read, saved, and every
/// item is checked on background threads (a file on a network share that has gone away can take a long
/// time to answer, and a view must never wait for that). Items whose volume is offline are kept and shown
/// dimmed (`unreachable`); only a file that is gone from a volume that is up is dropped.
@MainActor
final class ShelfModel: ObservableObject {
    /// The items, oldest first.
    @Published private(set) var urls: [URL] = []
    /// Items whose file cannot be reached right now (an unplugged drive, a sleeping share, a check that
    /// timed out). They stay on the shelf until the user removes them.
    @Published private(set) var unreachable: Set<URL> = []
    /// Bumped whenever icons have been read from disk, so views re-read `ShelfIcon`.
    @Published private(set) var iconRevision = 0
    /// A file drag is hovering over the floating shelf (draws its drop highlight).
    @Published var isDropTargeted = false
    /// The floating shelf is on screen (the menu bar tab's button reads this).
    @Published var isShelfOpen = false

    private var items = ShelfItems()
    private let store: ShelfStore?
    /// False until the saved list has been read; nothing is written before that, so a drop at launch can't
    /// overwrite items that haven't loaded yet.
    private(set) var isLoaded: Bool
    private var saveAfterLoad = false
    private var loadTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private let saveQueue = DispatchQueue(label: "com.kevo.orbit.shelf.save", qos: .utility)
    private let pendingSaves = DispatchGroup()

    /// How long a check of the items may take before the ones that haven't answered are shown as unreachable.
    private static let scanTimeout: TimeInterval = 3

    /// `store` nil makes a model that never reads or writes disk (snapshots).
    init(store: ShelfStore?) {
        self.store = store
        isLoaded = store == nil
    }

    /// A model over fixed URLs that never touches disk, for snapshots. The URLs need not exist.
    static func fixture(_ urls: [URL], unreachable: Set<URL> = []) -> ShelfModel {
        let model = ShelfModel(store: nil)
        model.items = ShelfItems(urls)
        model.urls = model.items.urls
        model.unreachable = Set(unreachable.map(\.standardizedFileURL)).intersection(model.urls)
        return model
    }

    /// Items that can be dragged out or opened right now.
    var availableURLs: [URL] { urls.filter { !unreachable.contains($0) } }

    // MARK: Loading and saving

    /// Reads the saved items (when the feature starts), off the main thread, then checks them. Files dropped
    /// before it finishes are kept.
    func load() {
        guard let store, !isLoaded, loadTask == nil else { return }
        loadTask = Task { [weak self] in
            let stored = await Task.detached(priority: .utility) { store.loadStored() }.value
            guard let self, !Task.isCancelled else { return }
            self.loadTask = nil
            var merged = stored
            let early = merged.add(self.items.urls) // dropped while loading: after the saved ones
            self.items = merged
            self.urls = merged.urls
            self.isLoaded = true
            if !early.isEmpty || self.saveAfterLoad {
                self.saveAfterLoad = false
                self.save()
            }
            self.refreshAvailability()
        }
    }

    /// Stops the work in flight, waits briefly for the last save to land, and forgets the items (the feature
    /// is off; `load()` reads them again when it is turned back on).
    func stop() {
        loadTask?.cancel()
        loadTask = nil
        scanTask?.cancel()
        scanTask = nil
        flush()
        guard store != nil else { return }
        isLoaded = false
        saveAfterLoad = false
        items = ShelfItems()
        urls = []
        unreachable = []
    }

    /// Waits (at most `timeout` seconds) for queued saves to finish: before quitting, and in checks.
    func flush(timeout: TimeInterval = 1) {
        _ = pendingSaves.wait(timeout: .now() + timeout)
    }

    private func commit() {
        urls = items.urls
        let current = Set(urls)
        if !unreachable.isSubset(of: current) { unreachable.formIntersection(current) }
        save()
    }

    /// Writes the list on a background queue (in order; the last write wins).
    private func save() {
        guard let store else { return }
        guard isLoaded else {
            saveAfterLoad = true
            return
        }
        let snapshot = items
        pendingSaves.enter()
        saveQueue.async { [pendingSaves] in
            do { try store.save(snapshot) } catch { Log.error("shelf: couldn't save the shelf: \(error.localizedDescription)") }
            pendingSaves.leave()
        }
    }

    // MARK: Changing the shelf

    /// Puts files on the shelf. Returns how many were new.
    @discardableResult
    func add(_ newURLs: [URL]) -> Int {
        let added = items.add(newURLs)
        guard !added.isEmpty else { return 0 }
        commit()
        primeIcons(for: added)
        return added.count
    }

    /// Takes one file off the shelf. The file itself is untouched.
    func remove(_ url: URL) {
        items.remove(url)
        commit()
    }

    /// Takes everything off the shelf. The files themselves are untouched.
    func clear() {
        guard !items.isEmpty else { return }
        items.removeAll()
        commit()
    }

    // MARK: Looking at the files

    /// Checks every item off the main thread (when the shelf is shown, and when the tab appears). A file that
    /// is gone from a volume that is up leaves the shelf (or is followed to where it moved); a file on a
    /// volume that is offline, or that can't be checked in time, stays and is marked unreachable.
    func refreshAvailability() {
        guard let store, isLoaded, scanTask == nil, !items.isEmpty else { return }
        let candidates = items.urls
        scanTask = Task { [weak self] in
            let outcomes = await ShelfScan.scan(candidates, store: store, timeout: Self.scanTimeout)
            guard let self, !Task.isCancelled else { return }
            self.scanTask = nil
            self.apply(outcomes, to: candidates)
        }
    }

    private func apply(_ outcomes: [ShelfScan.Outcome], to scanned: [URL]) {
        let byURL = Dictionary(outcomes.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var offline = Set<URL>()
        var present: [URL] = []
        var changed = false
        for url in scanned where items.contains(url) { // skip what the user removed meanwhile
            // No answer in time: out of reach for now, not gone.
            guard let outcome = byURL[url] else {
                offline.insert(url)
                continue
            }
            switch outcome.status {
            case .available:
                present.append(url)
            case .unreachable:
                offline.insert(url)
            case .missing:
                if let moved = outcome.movedTo {
                    items.replace(url, with: moved)
                    present.append(moved)
                } else {
                    items.remove(url)
                }
                changed = true
            }
        }
        let current = Set(items.urls)
        let newOffline = offline.intersection(current)
        if newOffline != unreachable { unreachable = newOffline }
        if changed { commit() }
        primeIcons(for: present)
    }

    /// A drag that started on the shelf ended with a move or delete result (`ShelfDragOutcome`). The result
    /// comes at the drop, before Finder has done anything (a cancelled Replace dialog or a failed move leaves
    /// the file where it was), so wait a moment, look again off the main thread, and drop only the files that
    /// are really gone. A file that can't be checked stays.
    func verifyMoved(_ dragged: [URL]) {
        guard store != nil, !dragged.isEmpty else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ShelfDragOutcome.recheckDelay))
            let gone = await Task.detached(priority: .utility) {
                dragged.filter { ShelfAvailability.status(of: $0, probe: ShelfAvailability.probe) == .missing }
            }.value
            guard let self, !gone.isEmpty else { return }
            for url in gone { self.items.remove(url) }
            self.commit()
        }
    }

    /// Reads the real icons of `targets` off the main thread, then tells the views.
    private func primeIcons(for targets: [URL]) {
        let unprimed = targets.filter { !ShelfIcon.isPrimed($0) }
        guard !unprimed.isEmpty else { return }
        Task { [weak self] in
            await Task.detached(priority: .utility) { ShelfIcon.prime(unprimed) }.value
            self?.iconRevision &+= 1
        }
    }
}

// MARK: - Checking items off the main thread

/// Runs `ShelfAvailability` on every item concurrently on background queues, gives up after a deadline, and never
/// piles up behind a stuck file system: a path whose check hasn't returned yet is not checked again.
enum ShelfScan {
    struct Outcome: Sendable {
        let url: URL
        let status: ShelfItemStatus
        /// Where the file was found again through its bookmark, when it was missing from its path.
        let movedTo: URL?
    }

    private static let stuck = StuckPaths()

    /// The outcomes that arrived within `timeout` seconds. Items without one didn't answer in time.
    static func scan(_ urls: [URL], store: ShelfStore, timeout: TimeInterval) async -> [Outcome] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Outcome], Never>) in
            let collector = Collector(expected: urls.count, continuation: continuation)
            for url in urls {
                guard stuck.begin(url.path) else {
                    collector.skip() // an earlier check of this path has not returned: leave it alone
                    continue
                }
                DispatchQueue.global(qos: .utility).async {
                    let status = ShelfAvailability.status(of: url, probe: ShelfAvailability.probe)
                    let moved = status == .missing ? store.follow(url) : nil
                    stuck.end(url.path)
                    collector.add(Outcome(url: url, status: status, movedTo: moved))
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) { collector.finish() }
        }
    }

    /// Paths with a check still running.
    private final class StuckPaths: @unchecked Sendable {
        private let lock = NSLock()
        private var running: Set<String> = []

        func begin(_ path: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return running.insert(path).inserted
        }

        func end(_ path: String) {
            lock.lock()
            defer { lock.unlock() }
            running.remove(path)
        }
    }

    /// Gathers outcomes and resumes the caller once: when all have answered, or at the deadline.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var results: [Outcome] = []
        private var remaining: Int
        private var continuation: CheckedContinuation<[Outcome], Never>?

        init(expected: Int, continuation: CheckedContinuation<[Outcome], Never>) {
            remaining = expected
            self.continuation = continuation
            if expected == 0 { finish() }
        }

        func add(_ outcome: Outcome) {
            lock.lock()
            results.append(outcome)
            remaining -= 1
            let done = remaining <= 0
            lock.unlock()
            if done { finish() }
        }

        func skip() {
            lock.lock()
            remaining -= 1
            let done = remaining <= 0
            lock.unlock()
            if done { finish() }
        }

        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            let gathered = results
            lock.unlock()
            pending?.resume(returning: gathered)
        }
    }
}

// MARK: - Icons and thumbnails

/// Icons for shelf entries. Views read `icon(for:)`, which never touches the file system: it returns the real
/// icon once `prime` has read it (off the main thread), and until then the icon for the file's type.
enum ShelfIcon {
    private static let cache = NSCache<NSURL, NSImage>()

    static func icon(for url: URL) -> NSImage {
        cache.object(forKey: url as NSURL) ?? typeIcon(for: url)
    }

    static func isPrimed(_ url: URL) -> Bool {
        cache.object(forKey: url as NSURL) != nil
    }

    /// The icon for the type its name suggests (a folder when the URL ends in a slash). No file system access.
    static func typeIcon(for url: URL) -> NSImage {
        if let type = UTType(filenameExtension: url.pathExtension), !url.pathExtension.isEmpty {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: url.hasDirectoryPath ? .folder : .data)
    }

    /// Reads the files' own icons into the cache. This stats each file: call it off the main thread.
    static func prime(_ urls: [URL]) {
        for url in urls {
            cache.setObject(NSWorkspace.shared.icon(forFile: url.path), forKey: url as NSURL)
        }
    }
}

/// Quick Look thumbnails for shelf tiles, remembered so a rebuilt tile doesn't flash its plain icon.
enum ShelfThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// A fresh thumbnail at `side` points (nil when the file is gone or Quick Look has none). Not main-actor:
    /// it checks the file first, which can take a while on a share that has gone away.
    static func load(_ url: URL, side: CGFloat) async -> NSImage? {
        guard ShelfAvailability.probe(url) == .exists else { return nil }
        guard let image = await Thumbnails.image(for: url, size: CGSize(width: side, height: side)) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
