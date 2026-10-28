import Foundation

/// The files on the shelf: an ordered list of unique file URLs. The shelf holds references to the
/// original files, never copies. Two URLs are the same item when they name the same path (a trailing
/// slash on a folder or `..` segments make no difference). A file added again keeps its first place.
public struct ShelfItems: Equatable, Sendable {
    /// The items, oldest first.
    public private(set) var urls: [URL]

    public init(_ urls: [URL] = []) {
        self.urls = []
        add(urls)
    }

    public var isEmpty: Bool { urls.isEmpty }
    public var count: Int { urls.count }

    public func contains(_ url: URL) -> Bool {
        guard let key = Self.key(url) else { return false }
        return urls.contains { Self.key($0) == key }
    }

    /// Appends `url` unless it is already on the shelf or is not a file URL. Returns whether it was added.
    @discardableResult
    public mutating func add(_ url: URL) -> Bool {
        guard url.isFileURL, !contains(url) else { return false }
        urls.append(url.standardizedFileURL)
        return true
    }

    /// Appends each of `newURLs` that is new, in order. Returns the ones that were added.
    @discardableResult
    public mutating func add(_ newURLs: [URL]) -> [URL] {
        newURLs.filter { add($0) }.map(\.standardizedFileURL)
    }

    /// Takes `url` off the shelf (nothing happens when it is not there). The file itself is untouched.
    public mutating func remove(_ url: URL) {
        guard let key = Self.key(url) else { return }
        urls.removeAll { Self.key($0) == key }
    }

    public mutating func removeAll() {
        urls.removeAll()
    }

    /// Drops the items `fileExists` says are gone (trashed or moved away). Returns the ones removed.
    @discardableResult
    public mutating func removeMissing(
        fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    ) -> [URL] {
        let missing = urls.filter { !fileExists($0) }
        guard !missing.isEmpty else { return [] }
        urls.removeAll { url in missing.contains(url) }
        return missing
    }

    private static func key(_ url: URL) -> String? {
        url.isFileURL ? url.standardizedFileURL.path : nil
    }
}
