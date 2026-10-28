import AppKit
import Combine
import OrbitCore
import SwiftUI

/// Shelf (spec §5.6): a floating glass shelf that holds references to files while you move between
/// windows and Spaces. It opens when you shake the cursor during a file drag (`ShakeWatcher`), from the
/// Shelf action in the wheel's Actions ring (`open(adding:near:)`) and from the Shelf tab of the menu bar
/// panel. Drop files on it; drag them back out later. Items persist (`ShelfStore`) until removed.
///
/// While the feature is off nothing runs: no event monitor, no window. `start()` loads the saved items and
/// installs the shake monitor (when "shake to open" is on); `stop()` removes the monitor and closes the
/// window. The saved items stay on disk.
@MainActor
final class ShelfFeature: SuiteFeature {
    let id = FeatureID.shelf
    private let context: SuiteContext
    private let settings: ShelfSettings
    private let model: ShelfModel
    private let window: ShelfWindowController
    private let watcher = ShakeWatcher()
    private var cancellables: Set<AnyCancellable> = []
    private var isRunning = false

    init(context: SuiteContext) {
        self.context = context
        settings = ShelfSettings(defaults: context.defaults)
        // The store only remembers where to write; nothing is read or created until `start()` / the first change.
        let directory = context.supportDirectory.appending(path: FeatureID.shelf.title, directoryHint: .isDirectory)
        model = ShelfModel(store: ShelfStore(directory: directory))
        model.showToast = { [weak context] content in context?.toasts.show(content) }
        window = ShelfWindowController(model: model, settings: settings)
        window.onDrop = { [weak self] urls in self?.model.add(urls) }
        watcher.onShake = { [weak self] point in self?.window.show(.nearPoint(point)) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        model.load()
        // The shake monitor exists only while the setting is on.
        settings.$shakeToOpen
            .removeDuplicates()
            .sink { [weak self] on in
                guard let self, self.isRunning else { return }
                if on { self.watcher.start() } else { self.watcher.stop() }
            }
            .store(in: &cancellables)
        settings.$keepOnTop
            .dropFirst()
            .receive(on: DispatchQueue.main) // `@Published` fires before the value is stored
            .sink { [weak self] _ in self?.window.applyLevel() }
            .store(in: &cancellables)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        cancellables.removeAll()
        watcher.stop()
        window.close()
        model.stop() // cancels work in flight, lets the last save land, and releases the items
    }

    /// The wheel's Shelf action: puts `urls` on the shelf and shows it centred on `point`.
    func open(adding urls: [URL], near point: CGPoint) {
        guard isRunning else {
            context.toasts.show(ToastContent(message: "Shelf is off", detail: "Turn it on in Settings, under Features.", isError: true))
            return
        }
        model.add(urls)
        window.show(.nearPoint(point))
    }

    func panelDidAppear() {
        // Files deleted or trashed while the panel was closed leave the list (a trashed file's bookmark still
        // finds it, but the shelf never follows it into the Trash); files renamed or moved on the same volume
        // are followed through their bookmark; files on a drive that is offline stay and show dimmed. The
        // checks run off the main thread.
        if isRunning { model.refreshAvailability() }
    }

    func makePanelView() -> AnyView {
        AnyView(ShelfPanelView(model: model, toggleShelf: { [weak self] in self?.toggleFromTab() },
                               hint: Self.hint(shakeToOpen: settings.shakeToOpen)))
    }

    func makeSettingsView() -> AnyView {
        AnyView(ShelfSettingsView(settings: settings, model: model))
    }

    static func snapshotViews() -> FeatureSnapshotViews {
        let model = ShelfModel.fixture(ShelfFixtures.demoURLs, unreachable: ShelfFixtures.demoOffline)
        let settings = ShelfSettings(defaults: SnapshotFixtures.defaults())
        return FeatureSnapshotViews(panel: ShelfPanelView(model: model, toggleShelf: {}, hint: hint(shakeToOpen: true)),
                                    settings: ShelfSettingsView(settings: settings, model: model))
    }

    // MARK: Menu bar tab

    private func toggleFromTab() {
        if window.isVisible {
            window.hide()
        } else {
            // Close the menu bar panel so the shelf isn't left behind it.
            context.closePanel()
            window.show(.remembered(screenPoint: NSEvent.mouseLocation))
        }
    }

    private static func hint(shakeToOpen: Bool) -> String {
        shakeToOpen ? "Shake the cursor while dragging files to open it anywhere."
                    : "Open it from here, or from the wheel's Actions ring."
    }
}
