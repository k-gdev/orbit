import Combine
import Foundation

/// The mic mute shortcut. Sound and Controls share one mic mute (`MicMuteService` in the app), so its
/// shortcut lives here rather than in either feature's settings.
public final class MicMuteSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let shortcut = "micMute.shortcut"
    }

    /// The global shortcut that mutes and unmutes the mic (default ⌃⌥M). Stored as JSON; unreadable data
    /// falls back to the default.
    @Published public var muteShortcut: KeyCombo {
        didSet {
            if let data = try? JSONEncoder().encode(muteShortcut) { defaults.set(data, forKey: Key.shortcut) }
        }
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        muteShortcut = defaults.data(forKey: Key.shortcut)
            .flatMap { try? JSONDecoder().decode(KeyCombo.self, from: $0) } ?? .micMuteDefault
    }
}
