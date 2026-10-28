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

        // Model and store: add persists, a move-out removes, a second model sees the result.
        let storeDirectory = dir.appending(path: "Shelf", directoryHint: .isDirectory)
        let model = ShelfModel(store: ShelfStore(directory: storeDirectory))
        check("a new model has nothing to load and wrote nothing", model.urls.isEmpty && !fm.fileExists(atPath: storeDirectory.path))
        check("add counts new files only", model.add([one, two, one]) == 2 && model.urls.count == 2)
        check("add wrote shelf.json", fm.fileExists(atPath: storeDirectory.appending(path: ShelfStore.fileName).path))
        model.removeMoved([one])
        let reloaded = ShelfModel(store: ShelfStore(directory: storeDirectory))
        reloaded.load()
        check("a moved-out file leaves the shelf, and a relaunch sees the rest", reloaded.urls.map(\.lastPathComponent) == ["two.txt"])
        check("the files themselves are untouched", fm.fileExists(atPath: one.path) && fm.fileExists(atPath: two.path))
        model.clear()
        check("clear empties the shelf but not the files", model.urls.isEmpty && fm.fileExists(atPath: two.path))

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
        watcher.stop()
        watcher.stop()
        check("stop removes it (idempotent)", !watcher.isRunning)

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
