import AppKit
import Combine
import OrbitCore

/// The ONE mic mute in Orbit, shared by the Sound tab's mute button, the Controls tab's Mic Mute toggle,
/// the global shortcut (`MicMuteSettings.muteShortcut`, default ⌃⌥M) and the crossed-out mic badge in
/// the menu bar. Flipping any of them updates the rest through `isMuted`. It needs no permission, so it
/// works whether or not Sound is on.
///
/// `FeatureRegistry` makes it active while Sound or Controls is on (`setActive`) and calls
/// `restoreOnQuit()` from `stopAll()`. While active: the shortcut is registered (hot key id `micMute`) and
/// the badge shows whenever the mic is muted. Going inactive unregisters, removes the badge, and unmutes
/// (restoring the input device's previous state) if Orbit muted it.
@MainActor
final class MicMuteService: NSObject, ObservableObject {
    /// Whether the input device is muted (by Orbit).
    @Published private(set) var isMuted = false
    /// Whether there is an input device to mute.
    @Published private(set) var isAvailable = false

    let settings: MicMuteSettings
    private let hotKeys: HotKeyCenter?
    private let isFixture: Bool
    private var active = false
    private var badge: NSStatusItem?
    private var shortcutSubscription: AnyCancellable?

    static let hotKeyID = "micMute"

    init(hotKeys: HotKeyCenter, settings: MicMuteSettings) {
        self.hotKeys = hotKeys
        self.settings = settings
        isFixture = false
        super.init()
    }

    /// A state-only stand-in for snapshots and previews: no hardware, no hot key, no status item.
    /// `setMuted` just flips `isMuted`.
    static func fixture(muted: Bool = false, available: Bool = true) -> MicMuteService {
        guard let defaults = UserDefaults(suiteName: "orbit.fixture.\(UUID().uuidString)") else {
            preconditionFailure("MicMuteService.fixture: no throwaway defaults suite")
        }
        let service = MicMuteService(fixtureSettings: MicMuteSettings(defaults: defaults))
        service.isMuted = muted
        service.isAvailable = available
        return service
    }

    private init(fixtureSettings: MicMuteSettings) {
        hotKeys = nil
        settings = fixtureSettings
        isFixture = true
        super.init()
    }

    /// Mutes or unmutes the current input device. Does nothing when no device is available.
    func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        if isFixture { isMuted = muted; return }
        guard applyHardwareMute(muted) else { return }
        isMuted = muted
        updateBadge()
    }

    func toggle() { setMuted(!isMuted) }

    /// On while Sound or Controls is on. Idempotent.
    func setActive(_ on: Bool) {
        guard !isFixture, on != active else { return }
        active = on
        if on {
            refreshAvailability()
            registerShortcut()
            shortcutSubscription = settings.$muteShortcut.dropFirst().sink { [weak self] _ in
                DispatchQueue.main.async { self?.registerShortcut() }
            }
            updateBadge()
        } else {
            shortcutSubscription = nil
            hotKeys?.unregister(id: Self.hotKeyID)
            if isMuted { setMuted(false) }
            removeBadge()
        }
    }

    /// Orbit is quitting: put the input device back as it was and drop the badge.
    func restoreOnQuit() {
        guard !isFixture else { return }
        if isMuted {
            restoreHardware()
            isMuted = false
        }
        hotKeys?.unregister(id: Self.hotKeyID)
        removeBadge()
        active = false
    }

    private func registerShortcut() {
        guard active else { return }
        if hotKeys?.register(settings.muteShortcut, id: Self.hotKeyID, action: { [weak self] in self?.toggle() }) == false {
            Log.info("mic mute shortcut \(settings.muteShortcut.display) is unavailable")
        }
    }

    // MARK: Menu bar badge

    private func updateBadge() {
        if active && isMuted { showBadge() } else { removeBadge() }
    }

    private func showBadge() {
        guard badge == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "mic.slash.fill", accessibilityDescription: "Microphone muted")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.toolTip = "Microphone muted by Orbit (\(settings.muteShortcut.display) to unmute). Click to unmute."
        item.button?.target = self
        item.button?.action = #selector(badgeClicked)
        badge = item
    }

    private func removeBadge() {
        guard let badge else { return }
        NSStatusBar.system.removeStatusItem(badge)
        self.badge = nil
    }

    @objc private func badgeClicked() { setMuted(false) }

    // MARK: Hardware — Implemented by the Sound task
    //
    // The Sound task fills these in with Core Audio HAL calls on the default input device
    // (`kAudioHardwarePropertyDefaultInputDevice`, the device's mute or volume property): remember the
    // device's previous mute/volume before muting, restore exactly that on unmute and on quit, and follow
    // input device changes. Until then they touch nothing, so the mic is never changed by this build.

    /// Re-reads whether an input device exists. Stub: none.
    private func refreshAvailability() {
        isAvailable = false
    }

    /// Mutes (remembering the previous state) or restores the input device. Returns whether it worked.
    /// Stub: does nothing and fails.
    private func applyHardwareMute(_ muted: Bool) -> Bool {
        false
    }

    /// Restores the input device's state from before Orbit muted it. Stub: nothing to restore.
    private func restoreHardware() {}
}
