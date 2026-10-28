import CoreServices
import Foundation

/// Watches the folders of a `ShelfWatchPlan` with one FSEvents stream (file-level events) and calls `onChange`
/// when something happened to one of the plan's files, once per burst of changes. The stream runs on a queue of
/// its own, so neither the folder checks that set it up (a drive that has gone away can take long to answer)
/// nor the callbacks ever touch the main thread; `onChange` is called on that queue and hops where it needs to.
///
/// `watch` replaces the target (a no-op when the plan is the same), `stop` ends it, and both are safe to call
/// from any thread and as often as you like without waiting for the file system. After `stop` returns, no
/// further `onChange` call is started.
public final class ShelfFolderWatcher: @unchecked Sendable {
    /// What FSEvents is told to watch for a folder of the plan: the folder as the file system really has it
    /// (symbolic links followed, since events carry real paths), or nil to leave it out because it can't be
    /// watched right now (its volume is not mounted, it is not there).
    public typealias FolderTransform = @Sendable (URL) -> URL?

    private let latency: TimeInterval
    private let folderTransform: FolderTransform
    private let onChange: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.kevo.orbit.shelf.watch", qos: .utility)

    private let lock = NSLock()
    private var requested = ShelfWatchPlan()
    /// Bumped by every `watch` and `stop`, so a set-up that was overtaken while it waited on the file system
    /// can tell and does nothing.
    private var generation = 0
    /// The callback state of the running stream, so `stop` can silence it at once without waiting for `queue`.
    private var activeBox: CallbackBox?
    /// The running stream. Only touched on `queue`.
    private var running: Running?

    /// `latency` is how long FSEvents gathers changes into one call (a burst is one `onChange`).
    public init(latency: TimeInterval = 0.5,
                folderTransform: @escaping FolderTransform = { ShelfFolderWatcher.reachableFolder($0) },
                onChange: @escaping @Sendable () -> Void) {
        self.latency = latency
        self.folderTransform = folderTransform
        self.onChange = onChange
    }

    deinit {
        // `running` is only touched on `queue`; by now nothing else can be using it.
        if let running { Self.tearDown(running) }
    }

    /// The default `FolderTransform`: a folder on a volume that is not mounted (a drive that is unplugged, a
    /// share that is asleep) or that is no longer there is left out, and the rest are resolved to their real
    /// path (`/private/var/...` for `/var/...`), which is how FSEvents spells the paths of its events. Blocks as
    /// long as the file system takes to answer, so it only ever runs on the watcher's queue.
    public static func reachableFolder(_ folder: URL) -> URL? {
        let root = ShelfAvailability.volumeRoot(of: folder)
        if root.path != "/", ShelfAvailability.probe(root) != .exists { return nil }
        // Not `URL.resolvingSymlinksInPath`, which turns `/private/var` back into `/var`.
        guard let real = realpath(folder.path, nil) else { return nil }
        defer { free(real) }
        return URL(fileURLWithPath: String(cString: real), isDirectory: true)
    }

    /// Makes `plan` the target: the stream for the previous plan is replaced, or ended when the plan is empty.
    public func watch(_ plan: ShelfWatchPlan) {
        lock.lock()
        guard plan != requested else {
            lock.unlock()
            return
        }
        requested = plan
        generation += 1
        let current = generation
        lock.unlock()
        queue.async { [self] in rebuild(for: plan, generation: current) }
    }

    /// Ends the watching; `watch` starts it again.
    public func stop() {
        lock.lock()
        let wasWatching = requested != ShelfWatchPlan()
        requested = ShelfWatchPlan()
        generation += 1
        let silenced = activeBox
        activeBox = nil
        lock.unlock()
        silenced?.cancel()
        guard wasWatching else { return }
        queue.async { [self] in
            if let running { Self.tearDown(running) }
            running = nil
        }
    }

    // MARK: The stream

    /// A running stream and what its callback needs. Retained by the stream's context, released with it.
    private final class Running {
        let stream: FSEventStreamRef
        let box: CallbackBox
        init(stream: FSEventStreamRef, box: CallbackBox) {
            self.stream = stream
            self.box = box
        }
    }

    private final class CallbackBox: @unchecked Sendable {
        let plan: ShelfWatchPlan
        let onChange: @Sendable () -> Void
        private let lock = NSLock()
        private var isCancelled = false

        init(plan: ShelfWatchPlan, onChange: @escaping @Sendable () -> Void) {
            self.plan = plan
            self.onChange = onChange
        }

        /// After this the stream's callbacks, including one already waiting on the queue, do nothing.
        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        var cancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    /// Replaces the running stream with one for `plan`. On `queue`.
    private func rebuild(for plan: ShelfWatchPlan, generation: Int) {
        if let running { Self.tearDown(running) }
        running = nil
        lock.lock()
        activeBox = nil
        lock.unlock()
        // The folder checks can take a long time on a stale share: look again afterwards whether this is still wanted.
        let resolved = plan.mapping(folders: folderTransform)
        guard !resolved.isEmpty, isCurrent(generation) else { return }

        let box = CallbackBox(plan: resolved, onChange: onChange)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passRetained(box).toOpaque(),
            retain: nil,
            release: { info in if let info { Unmanaged<CallbackBox>.fromOpaque(info).release() } },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents
                                             | kFSEventStreamCreateFlagWatchRoot
                                             | kFSEventStreamCreateFlagUseCFTypes)
        let paths = resolved.folders.map(\.path) as CFArray
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, Self.callback, &context, paths,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags) else {
            Unmanaged.passUnretained(box).release() // the stream never took the reference the context holds
            Log.error("shelf: couldn't watch the shelf's folders for changes")
            return
        }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            box.cancel()
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            Log.error("shelf: couldn't start watching the shelf's folders for changes")
            return
        }
        let started = Running(stream: stream, box: box)
        // `stop` or a newer `watch` may have come in while the stream was being made.
        lock.lock()
        let stillWanted = generation == self.generation
        if stillWanted { activeBox = box }
        lock.unlock()
        if stillWanted {
            running = started
        } else {
            Self.tearDown(started)
        }
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }

    /// Ends `running`'s stream. On `queue`, so no callback is in the middle of running.
    private static func tearDown(_ running: Running) {
        running.box.cancel()
        FSEventStreamStop(running.stream)
        FSEventStreamInvalidate(running.stream)
        FSEventStreamRelease(running.stream)
    }

    /// The events that say "look at everything again": the stream lost events, a watched folder itself was
    /// moved or removed, or a volume under it went away.
    private static let lookEverywhere = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs
                                                                | kFSEventStreamEventFlagUserDropped
                                                                | kFSEventStreamEventFlagKernelDropped
                                                                | kFSEventStreamEventFlagRootChanged
                                                                | kFSEventStreamEventFlagUnmount)

    private static let callback: FSEventStreamCallback = { _, info, count, eventPaths, eventFlags, _ in
        guard let info else { return }
        let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
        guard !box.cancelled else { return }
        var everywhere = false
        for index in 0..<count where eventFlags[index] & ShelfFolderWatcher.lookEverywhere != 0 { everywhere = true }
        if !everywhere {
            let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
            guard box.plan.isRelevant(paths) else { return }
        }
        box.onChange()
    }
}
