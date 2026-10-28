import Combine
import CoreGraphics
import Foundation

/// Shelf's persisted settings. Keys are prefixed `shelf.`.
public final class ShelfSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let shakeToOpen = "shelf.shakeToOpen"
        static let keepOnTop = "shelf.keepOnTop"
        static let frames = "shelf.frames"
    }

    /// Open the shelf when the cursor is shaken during a file drag (default on).
    @Published public var shakeToOpen: Bool { didSet { defaults.set(shakeToOpen, forKey: Key.shakeToOpen) } }

    /// Keep the shelf above other windows (default on); off lets ordinary windows cover it.
    @Published public var keepOnTop: Bool { didSet { defaults.set(keepOnTop, forKey: Key.keepOnTop) } }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        shakeToOpen = defaults.object(forKey: Key.shakeToOpen) as? Bool ?? true
        keepOnTop = defaults.object(forKey: Key.keepOnTop) as? Bool ?? true
    }

    /// Where the shelf last sat on the screen named `key` (a stable display key), or nil if never moved there.
    public func lastFrame(forScreen key: String) -> CGRect? {
        storedFrames()[key]
    }

    /// Remembers (or, with nil, forgets) the shelf's frame on the screen named `key`. A frame with no area
    /// or non-finite numbers is not stored.
    public func setLastFrame(_ frame: CGRect?, forScreen key: String) {
        var frames = storedFrames()
        if let frame, Self.isUsable(frame) { frames[key] = frame } else { frames[key] = nil }
        if let data = try? JSONEncoder().encode(frames) { defaults.set(data, forKey: Key.frames) }
    }

    private func storedFrames() -> [String: CGRect] {
        guard let data = defaults.data(forKey: Key.frames),
              let frames = try? JSONDecoder().decode([String: CGRect].self, from: data) else { return [:] }
        return frames.filter { Self.isUsable($0.value) }
    }

    private static func isUsable(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.width, frame.height].allSatisfy(\.isFinite) && frame.width > 0 && frame.height > 0
    }
}
