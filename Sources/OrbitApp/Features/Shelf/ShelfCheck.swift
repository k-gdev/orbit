import AppKit
import OrbitCore

/// Hidden command-line check of the Shelf's AppKit glue, with nothing shown on screen and no real files
/// touched (fixture files live in a temp folder removed at exit; the pasteboard is a private named one):
///
///     Orbit --check-shelf
///
/// It drives the drop target with a stand-in for AppKit's dragging info, the model and its store, the panel's
/// window settings (never ordered front), and the start/stop lifecycle. Prints PASS/FAIL per check and
/// exits 1 if any failed.
enum ShelfCheck {
    static let flag = "--check-shelf"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains(flag) else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL")  \(name)")
            if !ok { failures += 1 }
        }
        do {
            try run(check)
        } catch {
            print("FAIL  threw \(error)")
            failures += 1
        }
        print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    @MainActor
    private static func run(_ check: (String, Bool) -> Void) throws {
        let dir = SnapshotFixtures.directory()
        // Throwaway defaults (a plist in a temp folder), never the real ones.
        let (defaults, cleanup) = SnapshotFixtures.scopedDefaults()
        defer { cleanup() }
        let fm = FileManager.default
        func file(_ name: String) throws -> URL {
            let url = dir.appending(path: name, directoryHint: .notDirectory)
            try Data(name.utf8).write(to: url, options: .withoutOverwriting)
            return url
        }
        let one = try file("one.txt")
        let two = try file("two.txt")

        /// Runs the main run loop (so the model's background work can report back) until `condition` holds.
        func wait(_ timeout: TimeInterval = 6, until condition: () -> Bool) {
            let end = Date().addingTimeInterval(timeout)
            while !condition(), Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        }
        func shelfFile(_ directory: URL) -> String {
            (try? String(contentsOf: directory.appending(path: ShelfStore.fileName), encoding: .utf8)) ?? ""
        }

        // Model and store: loading is off the main thread, add persists, a move-out is re-checked, a relaunch sees it.
        let storeDirectory = dir.appending(path: "Shelf", directoryHint: .isDirectory)
        let model = ShelfModel(store: ShelfStore(directory: storeDirectory))
        model.load()
        check("load returns at once and reads in the background", !model.isLoaded)
        wait { model.isLoaded }
        check("a fresh shelf loads empty and wrote nothing", model.isLoaded && model.urls.isEmpty && !fm.fileExists(atPath: storeDirectory.path))
        check("add counts new files only", model.add([one, two, one]) == 2 && model.urls.count == 2)
        model.flush()
        check("add wrote shelf.json (in the background)", shelfFile(storeDirectory).contains("one.txt") && shelfFile(storeDirectory).contains("two.txt"))
        // A drag out ended with a move result. Finder really moved `one`; its move of `two` was cancelled.
        let movedAway = dir.appending(path: "one-moved.txt")
        try fm.moveItem(at: one, to: movedAway)
        model.verifyMoved([one, two])
        check("nothing leaves the shelf at the drop itself (Finder hasn't done anything yet)", model.urls.count == 2)
        wait { model.urls.count == 1 }
        check("after the re-check only the file that really went is dropped", model.urls.map(\.lastPathComponent) == ["two.txt"])
        model.flush()
        let reloaded = ShelfModel(store: ShelfStore(directory: storeDirectory))
        reloaded.load()
        wait { reloaded.isLoaded }
        check("a relaunch sees the rest", reloaded.urls.map(\.lastPathComponent) == ["two.txt"])
        check("the files themselves are untouched", fm.fileExists(atPath: movedAway.path) && fm.fileExists(atPath: two.path))

        // Items on a drive that is offline are kept; gone files are dropped; a renamed file is followed.
        let offlineDrive = URL(fileURLWithPath: "/Volumes/OrbitShelfCheck-\(UUID().uuidString)", isDirectory: true)
        let offlineFile = offlineDrive.appending(path: "Archive.zip", directoryHint: .notDirectory)
        let doomed = try file("doomed.txt")
        let renameMe = try file("rename-me.txt")
        model.add([offlineFile, doomed, renameMe])
        model.flush() // saved, with a bookmark for each file that exists
        try fm.removeItem(at: doomed)
        let renamed = dir.appending(path: "renamed.txt")
        try fm.moveItem(at: renameMe, to: renamed)
        model.refreshAvailability()
        wait { model.urls.count == 3 && model.urls.map(\.lastPathComponent) == ["two.txt", "Archive.zip", "renamed.txt"] }
        check("a file gone from a drive that is up is dropped", !model.urls.contains { $0.lastPathComponent == "doomed.txt" })
        check("a renamed file is followed and keeps its place", model.urls.map(\.lastPathComponent) == ["two.txt", "Archive.zip", "renamed.txt"])
        check("a file on a drive that is not there is kept, and shown as unreachable",
              model.urls.contains { $0.lastPathComponent == "Archive.zip" } && model.unreachable.contains { $0.lastPathComponent == "Archive.zip" })
        check("only that one is unreachable, and it is not offered for dragging all",
              model.unreachable.count == 1 && !model.availableURLs.contains { $0.lastPathComponent == "Archive.zip" })
        model.flush()
        check("the offline item is still in shelf.json", shelfFile(storeDirectory).contains("Archive.zip"))
        // After a relaunch it is still there, and with the drive absent still unreachable.
        let afterRelaunch = ShelfModel(store: ShelfStore(directory: storeDirectory))
        afterRelaunch.load()
        wait { afterRelaunch.isLoaded && afterRelaunch.unreachable.count == 1 }
        check("a relaunch keeps the offline item and marks it unreachable",
              afterRelaunch.urls.contains { $0.lastPathComponent == "Archive.zip" } && afterRelaunch.unreachable.count == 1)
        afterRelaunch.stop()
        check("stopping releases the items and leaves the file", afterRelaunch.urls.isEmpty && shelfFile(storeDirectory).contains("Archive.zip"))

        model.clear()
        model.flush()
        check("clear empties the shelf but not the files", model.urls.isEmpty && fm.fileExists(atPath: two.path))

        // A damaged shelf file is kept, never silently overwritten.
        let damagedDirectory = dir.appending(path: "Damaged", directoryHint: .isDirectory)
        try fm.createDirectory(at: damagedDirectory, withIntermediateDirectories: false)
        try Data("{ this is not json".utf8).write(to: damagedDirectory.appending(path: ShelfStore.fileName))
        let damaged = ShelfModel(store: ShelfStore(directory: damagedDirectory))
        damaged.load()
        wait { damaged.isLoaded }
        damaged.add([two])
        damaged.flush()
        let kept = (try? fm.contentsOfDirectory(atPath: damagedDirectory.path).filter { $0.hasPrefix("shelf.json.corrupt-") }) ?? []
        check("a damaged shelf file is moved aside before the first save, with its content", kept.count == 1
              && (try? String(contentsOf: damagedDirectory.appending(path: kept[0]), encoding: .utf8)) == "{ this is not json")
        check("and the new shelf file is valid", shelfFile(damagedDirectory).contains("two.txt"))

        // Drop target.
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("com.kevo.orbit.shelfcheck"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.writeObjects([one as NSURL, two as NSURL])
        let dropModel = ShelfModel.fixture([])
        let content = ShelfContentView(model: dropModel, close: {})
        var dropped: [URL] = []
        content.onDrop = { dropped = $0 }
        check("the drop target registers for file URLs", content.registeredDraggedTypes.contains(.fileURL))

        let copyAndMove = StubDraggingInfo(pasteboard: pasteboard, mask: [.copy, .move, .generic], source: nil)
        check("a Finder-style drag gets the copy cursor", content.draggingEntered(copyAndMove) == .copy)
        check("and the shelf lights up", dropModel.isDropTargeted)
        check("dropping hands over both files", content.performDragOperation(copyAndMove) && dropped.map(\.lastPathComponent) == ["one.txt", "two.txt"])
        check("the highlight is cleared after the drop", !dropModel.isDropTargeted)
        content.draggingEnded(copyAndMove)

        let moveOnly = StubDraggingInfo(pasteboard: pasteboard, mask: [.move], source: nil)
        check("a source that only allows move is refused", content.draggingEntered(moveOnly) == [])
        let genericOnly = StubDraggingInfo(pasteboard: pasteboard, mask: [.generic], source: nil)
        check("a generic-only source is accepted", content.draggingEntered(genericOnly) == .generic)
        let fromShelf = StubDraggingInfo(pasteboard: pasteboard, mask: [.copy, .move, .generic], source: ShelfDragSourceView())
        check("a drag that started on the shelf itself is refused", content.draggingEntered(fromShelf) == [])
        dropped = []
        check("and dropping it does nothing", !content.performDragOperation(fromShelf) && dropped.isEmpty)

        let text = NSPasteboard(name: NSPasteboard.Name("com.kevo.orbit.shelfcheck.text"))
        defer { text.releaseGlobally() }
        text.clearContents()
        text.setString("hello", forType: .string)
        check("a text drag is refused", content.draggingEntered(StubDraggingInfo(pasteboard: text, mask: [.copy], source: nil)) == [])
        content.draggingExited(nil)
        check("leaving clears the highlight", !dropModel.isDropTargeted)

        // The panel's window behaviour (never shown).
        let panel = ShelfPanel(content: ShelfContentView(model: dropModel, close: {}))
        check("the panel never becomes key (it must not take focus)", !panel.canBecomeKey && !panel.canBecomeMain)
        check("the panel is non-activating and resizable", panel.styleMask.contains(.nonactivatingPanel) && panel.styleMask.contains(.resizable))
        check("the panel shows on every Space and over full-screen apps",
              panel.collectionBehavior.contains(.canJoinAllSpaces) && panel.collectionBehavior.contains(.fullScreenAuxiliary))
        check("the panel floats", panel.level == .floating)
        check("the panel is not on screen", !panel.isVisible)
        panel.close()

        // The wheel: SHELF is in the Actions ring only while the app says the feature is on (the panel is never shown).
        let wheelSettings = SettingsStore(defaults: defaults)
        let wheel = WheelController(settings: wheelSettings)
        wheel.capabilities = { Capabilities() }
        let actionItems = [DroppedItem(url: one)]
        func ring(_ kind: WheelKind = .actions) -> [String] { wheel.content(for: kind, items: actionItems).slices.map(\.title) }
        let original = ["FLOAT", "AIRDROP", "COPY PATH", "TERMINAL", "COPY TO", "MOVE TO", "ARCHIVE"]
        check("the wheel's Actions ring is unchanged by default", ring() == original)
        wheel.shelfActionEnabled = { false }
        check("and with the Shelf off", ring() == original)
        wheel.shelfActionEnabled = { true }
        check("with the Shelf on, SHELF sits after FLOAT", ring() == ["FLOAT", "SHELF"] + original.dropFirst())
        let convertOn = ring(.convert)
        wheel.shelfActionEnabled = { false }
        check("the Convert wheel does not change", ring(.convert) == convertOn)
        check("the wheel is not on screen", !wheel.isVisible)

        // The job coordinator hands the Shelf action to the app, and refuses it headless.
        let coordinator = JobCoordinator(settings: wheelSettings)
        let shelfSlice = Slice(id: "actions.shelf", title: "SHELF", symbol: "tray", action: .action(.shelf, nil))
        var opened: (urls: [URL], point: CGPoint)?
        coordinator.openShelf = { urls, point in opened = (urls, point) }
        coordinator.perform(shelfSlice, items: actionItems, near: CGPoint(x: 10, y: 20))
        check("choosing SHELF opens the shelf with the files at the pointer", opened?.urls == [one] && opened?.point == CGPoint(x: 10, y: 20))
        opened = nil
        var headlessFailure = false
        coordinator.outcomeHandler = { outcome in if case .failed = outcome { headlessFailure = true } }
        coordinator.perform(shelfSlice, items: actionItems, near: .zero)
        check("a headless run reports it needs the app instead of opening anything", headlessFailure && opened == nil)

        // The shake watcher's monitor and the feature's lifecycle.
        let watcher = ShakeWatcher()
        check("the shake watcher starts off", !watcher.isRunning)
        watcher.start()
        watcher.start()
        check("start installs one monitor (idempotent)", watcher.isRunning)
        check("an idle watcher has no timer (nothing polls until a button is pressed)", !watcher.isPolling)
        watcher.stop()
        watcher.stop()
        check("stop removes it (idempotent)", !watcher.isRunning && !watcher.isPolling)

        // Polling glue with a scripted mouse and pasteboard (no real drag): a press starts a timer, a text drag is
        // never a shake, a file drag shaken is one shake, and releasing the button stops the timer.
        final class ScriptedMouse {
            var down = true
            var changeCount = 10
            var holdsFiles = false
            var point = CGPoint(x: 600, y: 400)
            var time: TimeInterval = 100
        }
        let mouse = ScriptedMouse()
        let scripted = ShakeWatcher(inputs: .init(buttonDown: { mouse.down }, changeCount: { mouse.changeCount },
                                                  holdsFiles: { mouse.holdsFiles }, location: { mouse.point }, now: { mouse.time }))
        var shakes: [CGPoint] = []
        scripted.onShake = { shakes.append($0) }
        /// Six 100 pt legs, six samples each, at 60 Hz.
        func shakeTheMouse() {
            var sign = 1.0
            for _ in 0..<6 {
                for _ in 0..<6 {
                    mouse.point.x += sign * 100 / 6
                    mouse.time += 1.0 / 60
                    scripted.poll()
                }
                sign = -sign
            }
        }
        scripted.pressBegan()
        check("a press starts the timer, slowly", scripted.isPolling && !scripted.isTracking)
        shakeTheMouse() // a file URL left from an earlier drag, nothing new dragged
        mouse.holdsFiles = true
        shakeTheMouse()
        check("a stale file pasteboard never counts, however hard the mouse is shaken", shakes.isEmpty && !scripted.isTracking)
        mouse.changeCount = 11 // a drag began and it holds files: now it is a file drag...
        mouse.holdsFiles = false // ...no: this one is text
        shakeTheMouse()
        check("shaking a text drag does nothing", shakes.isEmpty && !scripted.isTracking)
        mouse.down = false
        scripted.poll()
        check("releasing the button stops the timer", !scripted.isPolling)

        mouse.down = true
        mouse.changeCount = 20
        scripted.pressBegan()
        mouse.changeCount = 21
        mouse.holdsFiles = true
        shakeTheMouse()
        check("shaking a file drag opens the shelf, once", shakes.count == 1)
        check("and the timer is at the fast rate while the file drag lasts", scripted.isPolling && scripted.isTracking)
        mouse.down = false
        scripted.poll()
        check("the timer stops when the button is released", !scripted.isPolling && !scripted.isTracking)
        scripted.stop()

        let context = SuiteContext(settings: SettingsStore(defaults: defaults), suite: SuiteSettings(defaults: defaults), defaults: defaults,
                                   hotKeys: HotKeyCenter(), permissions: PermissionCenter(live: false, fixed: [:]),
                                   micMute: MicMuteService.fixture(), toasts: ToastCenter(),
                                   supportDirectory: dir.appending(path: "Support", directoryHint: .isDirectory))
        let feature = ShelfFeature(context: context)
        check("building the feature creates nothing on disk", !fm.fileExists(atPath: context.supportDirectory.path))
        feature.stop()
        feature.start()
        feature.start()
        feature.stop()
        feature.stop()
        check("start/stop in any order are harmless and leave nothing behind", !fm.fileExists(atPath: context.supportDirectory.path))
    }
}

/// A stand-in for AppKit's dragging info: a pasteboard, the source's allowed operations and its source object.
private final class StubDraggingInfo: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard
    let mask: NSDragOperation
    let source: Any?

    init(pasteboard: NSPasteboard, mask: NSDragOperation, source: Any?) {
        self.pasteboard = pasteboard
        self.mask = mask
        self.source = source
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { mask }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { source }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
}
