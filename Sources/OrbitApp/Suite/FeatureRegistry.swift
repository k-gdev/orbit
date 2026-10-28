import Combine
import OrbitCore

/// Owns one instance of every feature and is the only thing that starts and stops them. Turning a
/// feature on from Settings goes through `setEnabled`, which persists the choice, asks for the
/// permissions the feature requests on enable, and starts it; turning it off stops all its work.
@MainActor
final class FeatureRegistry: ObservableObject {
    let context: SuiteContext
    private let features: [FeatureID: any SuiteFeature]

    /// The features whose `start()` has run without a matching `stop()`.
    @Published private(set) var running: Set<FeatureID> = []

    init(context: SuiteContext, features: [any SuiteFeature]) {
        self.context = context
        var byID: [FeatureID: any SuiteFeature] = [:]
        for feature in features { byID[feature.id] = feature }
        self.features = byID
    }

    /// The registry of every feature in `FeatureID.allCases`, each built with `init(context:)`.
    static func standard(context: SuiteContext) -> FeatureRegistry {
        FeatureRegistry(context: context, features: FeatureID.allCases.map { featureType(for: $0).init(context: context) })
    }

    /// The class implementing each feature (also used by the snapshot CLI for `snapshotViews()`).
    static func featureType(for id: FeatureID) -> any SuiteFeature.Type {
        switch id {
        case .sound: SoundFeature.self
        case .system: SystemFeature.self
        case .displays: DisplaysFeature.self
        case .windows: WindowsFeature.self
        case .clipboard: ClipboardFeature.self
        case .shelf: ShelfFeature.self
        case .wallpaper: WallpaperFeature.self
        case .controls: ControlsFeature.self
        }
    }

    /// The instance for `id`.
    func feature(_ id: FeatureID) -> any SuiteFeature {
        guard let feature = features[id] else { preconditionFailure("FeatureRegistry has no \(id.rawValue) feature") }
        return feature
    }

    func isEnabled(_ id: FeatureID) -> Bool { context.suite.isEnabled(id) }

    /// The enabled features in tab order (the panel's tabs).
    var enabledInOrder: [FeatureID] { context.suite.enabledInOrder.filter { features[$0] != nil } }

    /// At launch: starts every enabled feature. Never prompts for permissions (the user granted or
    /// declined them when turning the feature on).
    func startEnabled() {
        for id in enabledInOrder { start(id) }
        updateMicMute()
    }

    /// Turns `id` on or off: persists it, then on → asks for its `requestOnEnable` permissions that are
    /// not granted yet and starts it; off → stops it.
    func setEnabled(_ id: FeatureID, _ on: Bool) {
        context.suite.setEnabled(id, on)
        if on {
            context.permissions.refresh()
            for use in id.permissions where use.requestOnEnable && context.permissions.status(use.permission) != .granted {
                context.permissions.request(use.permission)
            }
            start(id)
        } else {
            stop(id)
        }
        updateMicMute()
    }

    /// Orbit is quitting: stops every running feature and restores the mic.
    func stopAll() {
        for id in FeatureID.allCases where running.contains(id) { stop(id) }
        context.micMute.restoreOnQuit()
    }

    private func start(_ id: FeatureID) {
        guard let feature = features[id], !running.contains(id) else { return }
        Log.info("suite: starting \(id.rawValue)")
        feature.start()
        running.insert(id)
    }

    private func stop(_ id: FeatureID) {
        guard let feature = features[id], running.contains(id) else { return }
        Log.info("suite: stopping \(id.rawValue)")
        feature.stop()
        running.remove(id)
    }

    /// The shared mic mute is live while Sound or Controls is on.
    private func updateMicMute() {
        context.micMute.setActive(isEnabled(.sound) || isEnabled(.controls))
    }
}
