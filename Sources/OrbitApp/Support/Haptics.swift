import AppKit
import OrbitCore

/// Trackpad feedback: a light tick when the wheel's highlight moves, a stronger
/// one when a job finishes. Silent when `SettingsStore.hapticsEnabled` is off.
@MainActor
enum Haptics {
    /// The store whose `hapticsEnabled` gates feedback; feedback plays when unset.
    static weak var settings: SettingsStore?

    static func tick() { perform(.alignment) }

    static func done() { perform(.levelChange) }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard settings?.hapticsEnabled ?? true else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
