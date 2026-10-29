import Combine
import Foundation

/// The suite's own persisted settings: which features are on and the menu bar panel's last tab.
/// Feature settings live in each feature's `<Feature>Settings`, under keys prefixed with its id.
public final class SuiteSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let enabledFeatures = "suite.enabledFeatures"
        static let lastTab = "suite.lastTab"
    }

    /// The features that are turned on. Stored as raw values in tab order; unknown ids are dropped on read.
    /// Prefer `FeatureRegistry.setEnabled` in the app, which also starts or stops the feature.
    @Published public var enabledFeatures: Set<FeatureID> {
        didSet { defaults.set(Self.ordered(enabledFeatures).map(\.rawValue), forKey: Key.enabledFeatures) }
    }

    /// The tab the panel showed last, or nil before the first open.
    @Published public var lastTab: FeatureID? {
        didSet {
            if let lastTab { defaults.set(lastTab.rawValue, forKey: Key.lastTab) }
            else { defaults.removeObject(forKey: Key.lastTab) }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.stringArray(forKey: Key.enabledFeatures) {
            enabledFeatures = Set(raw.compactMap(FeatureID.init(rawValue:)))
        } else {
            enabledFeatures = Set(FeatureID.allCases.filter(\.isOnByDefault))
        }
        lastTab = defaults.string(forKey: Key.lastTab).flatMap(FeatureID.init(rawValue:))
    }

    public func isEnabled(_ id: FeatureID) -> Bool { enabledFeatures.contains(id) }

    /// Turns one feature on or off in the persisted set (no side effects beyond that).
    public func setEnabled(_ id: FeatureID, _ on: Bool) {
        if on { enabledFeatures.insert(id) } else { enabledFeatures.remove(id) }
    }

    /// The enabled features in tab order.
    public var enabledInOrder: [FeatureID] { Self.ordered(enabledFeatures) }

    private static func ordered(_ set: Set<FeatureID>) -> [FeatureID] {
        FeatureID.allCases.filter(set.contains)
    }
}
