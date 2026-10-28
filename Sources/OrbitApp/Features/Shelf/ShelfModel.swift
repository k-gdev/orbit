import AppKit
import Combine
import OrbitCore
import UniformTypeIdentifiers

/// What is on the shelf, as the floating shelf and the menu bar tab show it, persisted through a
/// `ShelfStore` after every change. The shelf holds references to the original files: nothing here moves,
/// copies or deletes a file. Main actor only.
@MainActor
final class ShelfModel: ObservableObject {
    /// The items, oldest first.
    @Published private(set) var urls: [URL] = []
    /// A file drag is hovering over the floating shelf (draws its drop highlight).
    @Published var isDropTargeted = false
    /// The floating shelf is on screen (the menu bar tab's button reads this).
    @Published var isShelfOpen = false

    private var items = ShelfItems()
    private let store: ShelfStore?

    /// `store` nil makes a model that never reads or writes disk (snapshots).
    init(store: ShelfStore?) {
        self.store = store
    }

    /// A model over fixed URLs that never touches disk, for snapshots. The URLs need not exist.
    static func fixture(_ urls: [URL]) -> ShelfModel {
        let model = ShelfModel(store: nil)
        model.items = ShelfItems(urls)
        model.urls = model.items.urls
        return model
    }

    /// Reads the saved items (when the feature starts).
    func load() {
        guard let store else { return }
        items = store.load()
        urls = items.urls
    }

    /// Puts files on the shelf. Returns how many were new.
    @discardableResult
    func add(_ newURLs: [URL]) -> Int {
        let added = items.add(newURLs)
        if !added.isEmpty { commit() }
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

    /// Drops items whose file has been trashed or moved away. The file checks run off the main thread (a
    /// file on a network share that has gone away can take a while to answer). Never runs for a fixture model.
    func removeMissing() {
        guard store != nil else { return }
        let candidates = items.urls
        Task { [weak self] in
            let missing = await Task.detached(priority: .utility) {
                Set(candidates.filter { !FileManager.default.fileExists(atPath: $0.path) })
            }.value
            guard let self, !missing.isEmpty else { return }
            // Only what was found missing leaves; anything added in the meantime stays.
            if !self.items.removeMissing(fileExists: { !missing.contains($0) }).isEmpty { self.commit() }
        }
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

    private func commit() {
        urls = items.urls
        guard let store else { return }
        do { try store.save(items) } catch { Log.error("shelf: couldn't save the shelf: \(error.localizedDescription)") }
    }
}

/// Icons for shelf entries.
enum ShelfIcon {
    /// The file's own icon when it exists, else the icon for its type (so a fixture or a file that has just
    /// gone still shows something sensible).
    static func icon(for url: URL) -> NSImage {
        if FileManager.default.fileExists(atPath: url.path) { return NSWorkspace.shared.icon(forFile: url.path) }
        if let type = UTType(filenameExtension: url.pathExtension), !url.pathExtension.isEmpty {
            return NSWorkspace.shared.icon(for: type)
        }
        return NSWorkspace.shared.icon(for: url.hasDirectoryPath ? .folder : .data)
    }
}

/// Quick Look thumbnails for shelf tiles, remembered so a rebuilt tile doesn't flash its plain icon.
@MainActor
enum ShelfThumbnails {
    private static let cache = NSCache<NSURL, NSImage>()

    static func cached(_ url: URL) -> NSImage? { cache.object(forKey: url as NSURL) }

    /// A fresh thumbnail at `side` points (nil when the file is gone or Quick Look has none).
    static func load(_ url: URL, side: CGFloat) async -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let image = await Thumbnails.image(for: url, size: CGSize(width: side, height: side)) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
