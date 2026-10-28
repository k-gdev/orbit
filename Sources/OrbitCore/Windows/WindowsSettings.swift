import Combine
import Foundation

/// The Windows feature's persisted settings, under `windows.`-prefixed keys.
public final class WindowsSettings: ObservableObject {
    /// How long the pointer must rest on a Dock icon before its preview opens, in seconds.
    public static let previewDelayRange: ClosedRange<Double> = 0...1.5
    public static let defaultPreviewDelay = 0.35

    private let defaults: UserDefaults

    private enum Key {
        static let dockPreviewEnabled = "windows.dockPreviewEnabled"
        static let previewDelay = "windows.previewDelay"
        static let showMinimised = "windows.showMinimised"
    }

    /// Show window thumbnails when hovering over a Dock icon (default on). Off, the Dock is not watched.
    @Published public var dockPreviewEnabled: Bool {
        didSet { defaults.set(dockPreviewEnabled, forKey: Key.dockPreviewEnabled) }
    }

    /// Hover time before the preview opens (default 0.35 s), kept within `previewDelayRange`.
    @Published public var previewDelay: Double {
        didSet {
            let clamped = Self.clampedDelay(previewDelay)
            if clamped != previewDelay { previewDelay = clamped }
            defaults.set(clamped, forKey: Key.previewDelay)
        }
    }

    /// List minimised windows in the Dock preview and the Windows tab (default on).
    @Published public var showMinimised: Bool {
        didSet { defaults.set(showMinimised, forKey: Key.showMinimised) }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dockPreviewEnabled = defaults.object(forKey: Key.dockPreviewEnabled) as? Bool ?? true
        previewDelay = Self.clampedDelay((defaults.object(forKey: Key.previewDelay) as? NSNumber)?.doubleValue ?? Self.defaultPreviewDelay)
        showMinimised = defaults.object(forKey: Key.showMinimised) as? Bool ?? true
    }

    private static func clampedDelay(_ value: Double) -> Double {
        guard value.isFinite else { return defaultPreviewDelay }
        return min(max(value, previewDelayRange.lowerBound), previewDelayRange.upperBound)
    }
}
