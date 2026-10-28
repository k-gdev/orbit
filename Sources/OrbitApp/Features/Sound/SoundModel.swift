import AppKit
import Combine
import OrbitCore
import SwiftUI

/// An app's icon in the mixer: its real icon, or (fixtures, unknown apps) an SF Symbol on a coloured tile.
enum SoundAppIcon {
    case image(NSImage)
    case symbol(String, Color)
}

/// An app as the mixer shows it.
struct SoundAppIdentity: Identifiable {
    let bundleID: String
    let name: String
    let icon: SoundAppIcon
    var id: String { bundleID }
}

/// One row of the Apps list.
struct SoundAppItem: Identifiable {
    let identity: SoundAppIdentity
    let isPlaying: Bool
    /// Where the app plays when set to Same as Output (its own device choice, else the system output);
    /// nil = the system output.
    var followedOutputUID: String?
    /// Orbit couldn't take over this app's audio, so its volume and output are not applied.
    var tapFailed = false
    var id: String { identity.bundleID }
    var bundleID: String { identity.bundleID }
    var name: String { identity.name }
}

/// A device in a menu.
struct SoundDeviceItem: Identifiable, Equatable {
    let uid: String
    let name: String
    let symbol: String
    var id: String { uid }
}

/// Why the Apps list can't show sliders.
enum SoundAppsStatus: Equatable {
    case available
    /// System Audio Recording is not granted (or macOS can't tell).
    case needsPermission
    /// Process taps need macOS 14.2.
    case needsNewerSystem
}

/// What the Sound tab shows and what its controls do. The feature fills it from the hardware while it runs;
/// `fixture()` fills it with Kevo's devices for snapshots, where the controls only change the model.
@MainActor
final class SoundPanelModel: ObservableObject {
    @Published var outputs: [SoundDeviceItem] = []
    @Published var inputs: [SoundDeviceItem] = []
    @Published var defaultOutputUID: String?
    @Published var systemOutputUID: String?
    @Published var defaultInputUID: String?
    /// The output's master volume in percent, nil when the device has no volume control.
    @Published var outputVolume: Double?
    @Published var outputMuted = false
    /// The input level in percent, nil when the device has none.
    @Published var inputVolume: Double?
    @Published var apps: [SoundAppItem] = []
    @Published var appsStatus: SoundAppsStatus = .available

    let settings: SoundSettings
    let micMute: MicMuteService

    /// What the controls do to the system (nil in fixtures, where they only change the model).
    weak var hardware: SoundPanelActions?

    init(settings: SoundSettings, micMute: MicMuteService) {
        self.settings = settings
        self.micMute = micMute
    }

    func output(uid: String?) -> SoundDeviceItem? { outputs.first { $0.uid == uid } }
    func input(uid: String?) -> SoundDeviceItem? { inputs.first { $0.uid == uid } }

    // MARK: Devices

    func selectOutput(_ uid: String) {
        if let hardware { hardware.selectOutput(uid) } else { defaultOutputUID = uid }
    }

    func selectSystemOutput(_ uid: String) {
        if let hardware { hardware.selectSystemOutput(uid) } else { systemOutputUID = uid }
    }

    /// Choosing a microphone while "keep preferred microphone" is on makes it the preferred one, so Orbit
    /// doesn't switch straight back.
    func selectInput(_ uid: String) {
        if settings.keepPreferredMic { settings.preferredMicUID = uid }
        if let hardware { hardware.selectInput(uid) } else { defaultInputUID = uid }
    }

    func setOutputVolume(_ percent: Double) {
        outputVolume = percent
        if percent > 0 { outputMuted = false }
        hardware?.setOutputVolume(Float(percent / 100))
    }

    func setInputVolume(_ percent: Double) {
        inputVolume = percent
        hardware?.setInputVolume(Float(percent / 100))
    }

    // MARK: Apps

    func preference(for bundleID: String) -> AppAudioPreference { settings.preference(for: bundleID) }

    func setVolume(_ percent: Double, for bundleID: String) {
        var preference = settings.preference(for: bundleID)
        preference.volume = percent.rounded()
        settings.setPreference(preference, for: bundleID)
    }

    func toggleMute(_ bundleID: String) {
        var preference = settings.preference(for: bundleID)
        preference.muted.toggle()
        settings.setPreference(preference, for: bundleID)
    }

    /// nil = Same as Output.
    func setOutput(_ uid: String?, for bundleID: String) {
        var preference = settings.preference(for: bundleID)
        preference.outputUID = uid
        settings.setPreference(preference, for: bundleID)
    }

    func reset(_ bundleID: String) {
        settings.setPreference(.unity, for: bundleID)
    }

    func togglePin(_ bundleID: String) {
        if settings.isPinned(bundleID) { settings.unpin(bundleID) } else { settings.pin(bundleID) }
        hardware?.appsChanged()
    }

    func toggleShowAll() {
        settings.showAllApps.toggle()
        hardware?.appsChanged()
    }

    func requestPermission() {
        hardware?.requestPermission()
    }
}

/// The system side of the Sound tab's controls, implemented by `SoundFeature`.
@MainActor
protocol SoundPanelActions: AnyObject {
    func selectOutput(_ uid: String)
    func selectSystemOutput(_ uid: String)
    func selectInput(_ uid: String)
    func setOutputVolume(_ value: Float)
    func setInputVolume(_ value: Float)
    func requestPermission()
    /// Pins or "show all" changed: rebuild the Apps list.
    func appsChanged()
}

// MARK: - Resolving apps

/// Names and icons for bundle IDs, from the running app or its bundle on disk. Cached per bundle ID.
@MainActor
final class SoundAppDirectory {
    private var cache: [String: SoundAppIdentity] = [:]

    func identity(for bundleID: String, pid: pid_t? = nil) -> SoundAppIdentity {
        if let cached = cache[bundleID] { return cached }
        let running = pid.flatMap { NSRunningApplication(processIdentifier: $0) }.flatMap { $0.bundleIdentifier == bundleID ? $0 : nil }
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        var name = running?.localizedName
        var icon = running?.icon
        if name == nil || icon == nil, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            name = name ?? FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            icon = icon ?? NSWorkspace.shared.icon(forFile: url.path)
        }
        let fallbackName = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        let identity = SoundAppIdentity(bundleID: bundleID, name: name ?? fallbackName,
                                        icon: icon.map(SoundAppIcon.image) ?? .symbol("app.dashed", .gray))
        cache[bundleID] = identity
        return identity
    }

    /// Whether the app is user-facing (a Dock or menu bar app) rather than a system daemon.
    static func isListable(_ bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).contains {
            $0.activationPolicy == .regular || $0.activationPolicy == .accessory
        }
    }

    /// Running Dock apps, for "Add App" in Settings.
    func runningApps() -> [SoundAppIdentity] {
        let ownBundle = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> SoundAppIdentity? in
                guard let id = app.bundleIdentifier, id != ownBundle, seen.insert(id).inserted else { return nil }
                return identity(for: id, pid: app.processIdentifier)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Fixture

extension SoundPanelModel {
    /// Kevo's setup (devices from hardware.md) with the mockup's apps: Discord at 85 %, Chrome boosted to
    /// 130 % on the MacBook speakers, Music at 60 %, RingCentral pinned, Slack muted and pinned. No hardware.
    static func fixture(settings: SoundSettings, micMute: MicMuteService, status: SoundAppsStatus = .available) -> SoundPanelModel {
        let model = SoundPanelModel(settings: settings, micMute: micMute)
        let devices = SoundFixtures.devices
        let names = AudioDeviceNaming.displayNames(for: devices)
        model.outputs = devices.filter(\.hasOutput).map { SoundDeviceItem(uid: $0.uid, name: names[$0.uid] ?? $0.name, symbol: $0.symbol(forInput: false)) }
        model.inputs = devices.filter(\.hasInput).map { SoundDeviceItem(uid: $0.uid, name: names[$0.uid] ?? $0.name, symbol: $0.symbol(forInput: true)) }
        model.defaultOutputUID = SoundFixtures.headset
        model.systemOutputUID = SoundFixtures.speakers
        model.defaultInputUID = SoundFixtures.headset
        model.outputVolume = 87
        model.inputVolume = 100
        model.appsStatus = status
        settings.pin("com.ringcentral.glip")
        settings.pin("com.tinyspeck.slackmacgap")
        settings.setPreference(AppAudioPreference(volume: 85), for: "com.hnc.Discord")
        settings.setPreference(AppAudioPreference(volume: 130, outputUID: SoundFixtures.speakers), for: "com.google.Chrome")
        settings.setPreference(AppAudioPreference(volume: 60), for: "com.apple.Music")
        settings.setPreference(AppAudioPreference(volume: 70, muted: true), for: "com.tinyspeck.slackmacgap")
        let apps = SoundFixtures.apps
        let visible = AudioAppList.visible(apps.map(\.candidate), pinned: settings.pinnedBundleIDs,
                                           customised: Set(settings.appStates.keys), showAll: settings.showAllApps)
        model.apps = visible.compactMap { candidate in
            apps.first { $0.identity.bundleID == candidate.bundleID }.map { SoundAppItem(identity: $0.identity, isPlaying: candidate.isPlaying) }
        }
        return model
    }
}

/// Fixture data for snapshots: Kevo's audio devices (hardware.md) and a few apps drawn as symbols.
enum SoundFixtures {
    static let headset = "AppleUSBAudioEngine:SteelSeries:SteelSeries Arctis Nova 5:132000:2,1"
    static let speakers = "BuiltInSpeakerDevice"
    static let builtInMic = "BuiltInMicrophoneDevice"

    static let devices: [AudioDeviceSummary] = [
        AudioDeviceSummary(uid: "04722405-0000-0000-201A-0104B53C2278", name: "K272HUL", inputChannels: 0, outputChannels: 2, transport: .displayPort),
        AudioDeviceSummary(uid: "05E321B4-0000-0000-0D23-0104B53B2178", name: "Q27G4ZD", inputChannels: 0, outputChannels: 2, transport: .displayPort),
        AudioDeviceSummary(uid: "30AECB62-0000-0000-1E24-0104B53C2278", name: "P27u-20", inputChannels: 0, outputChannels: 2, transport: .displayPort),
        AudioDeviceSummary(uid: "30AECB62-0000-0000-1E24-0104B53C2278_0AE0D000", name: "P27u-20", inputChannels: 0, outputChannels: 2, transport: .displayPort),
        AudioDeviceSummary(uid: headset, name: "SteelSeries Arctis Nova 5", inputChannels: 1, outputChannels: 2, transport: .usb),
        AudioDeviceSummary(uid: builtInMic, name: "MacBook Pro Microphone", inputChannels: 1, outputChannels: 0, transport: .builtIn),
        AudioDeviceSummary(uid: speakers, name: "MacBook Pro Speakers", inputChannels: 0, outputChannels: 2, transport: .builtIn),
        AudioDeviceSummary(uid: "MSLoopbackDriverDevice_UID", name: "Microsoft Teams Audio", inputChannels: 1, outputChannels: 1, transport: .virtual),
    ]

    struct App {
        let identity: SoundAppIdentity
        let candidate: AudioAppCandidate
    }

    static let apps: [App] = [
        app("com.hnc.Discord", "Discord", "bubble.left.and.bubble.right.fill", Color(red: 0.35, green: 0.40, blue: 0.95), playing: true),
        app("com.google.Chrome", "Google Chrome", "globe", Color(red: 0.26, green: 0.52, blue: 0.96), playing: true),
        app("com.apple.Music", "Music", "music.note", Color(red: 0.98, green: 0.30, blue: 0.40), playing: true),
        app("com.ringcentral.glip", "RingCentral", "phone.fill", Color(red: 0.98, green: 0.53, blue: 0.0)),
        app("com.tinyspeck.slackmacgap", "Slack", "number", Color(red: 0.29, green: 0.08, blue: 0.29)),
        app("ru.keepcoder.Telegram", "Telegram", "paperplane.fill", Color(red: 0.16, green: 0.62, blue: 0.89)),
        app("com.apple.Safari", "Safari", "safari.fill", Color(red: 0.10, green: 0.55, blue: 0.95)),
    ]

    private static func app(_ id: String, _ name: String, _ symbol: String, _ tint: Color, playing: Bool = false) -> App {
        App(identity: SoundAppIdentity(bundleID: id, name: name, icon: .symbol(symbol, tint)),
            candidate: AudioAppCandidate(bundleID: id, name: name, isRunning: true, isPlaying: playing, isListable: true))
    }
}
