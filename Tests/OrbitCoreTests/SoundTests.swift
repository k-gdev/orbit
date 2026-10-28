import Combine
import Foundation
import Testing
@testable import OrbitCore

/// Sound (spec §5.1): per-app volume and routing decisions, the volume curve, process grouping, the
/// preferred-mic policy, the shared mic mute's restore logic, and the Sound settings store.
@Suite struct SoundTests {
    /// Every Sound setting persists under a `sound.` key, and per-app states only while
    /// "remember" is on.
    @Test func settingsRoundTrip() {
        let (d, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let fresh = SoundSettings(defaults: d)
        #expect(fresh.pinnedBundleIDs.isEmpty)
        #expect(fresh.appStates.isEmpty)
        #expect(fresh.rememberAppStates)
        #expect(fresh.preferredMicUID == nil)
        #expect(!fresh.keepPreferredMic)
        #expect(!fresh.showAllApps)
        #expect(fresh.preference(for: "com.google.Chrome") == .unity)

        let s = SoundSettings(defaults: d)
        s.pin("com.hnc.Discord")
        s.pin("com.google.Chrome")
        s.pin("com.hnc.Discord")                       // pinning twice keeps one entry
        s.setPreference(AppAudioPreference(volume: 130, muted: false, outputUID: "BuiltInSpeakerDevice"), for: "com.google.Chrome")
        s.setPreference(AppAudioPreference(volume: 60, muted: true), for: "com.tinyspeck.slackmacgap")
        s.preferredMicUID = "BuiltInMicrophoneDevice"
        s.keepPreferredMic = true
        s.showAllApps = true

        let r = SoundSettings(defaults: d)
        #expect(r.pinnedBundleIDs == ["com.hnc.Discord", "com.google.Chrome"])
        #expect(r.isPinned("com.google.Chrome"))
        #expect(r.preference(for: "com.google.Chrome") == AppAudioPreference(volume: 130, muted: false, outputUID: "BuiltInSpeakerDevice"))
        #expect(r.preference(for: "com.tinyspeck.slackmacgap").muted)
        #expect(r.preferredMicUID == "BuiltInMicrophoneDevice")
        #expect(r.keepPreferredMic)
        #expect(r.showAllApps)
        #expect(d.data(forKey: "sound.appStates") != nil)

        // Back to 100 %, unmuted, Same as Output: the entry goes away instead of lingering.
        r.setPreference(.unity, for: "com.google.Chrome")
        #expect(SoundSettings(defaults: d).appStates.keys.sorted() == ["com.tinyspeck.slackmacgap"])
        r.unpin("com.hnc.Discord")
        #expect(SoundSettings(defaults: d).pinnedBundleIDs == ["com.google.Chrome"])
        r.preferredMicUID = nil
        #expect(SoundSettings(defaults: d).preferredMicUID == nil)

        // "Remember" off: states live for this run only and the stored copy is removed.
        r.rememberAppStates = false
        #expect(d.data(forKey: "sound.appStates") == nil)
        r.setPreference(AppAudioPreference(volume: 20), for: "com.apple.Music")
        #expect(r.preference(for: "com.apple.Music").volume == 20)
        let forgetful = SoundSettings(defaults: d)
        #expect(!forgetful.rememberAppStates)
        #expect(forgetful.appStates.isEmpty)
        // Turning it back on saves what this run has.
        forgetful.setPreference(AppAudioPreference(volume: 45), for: "com.apple.Music")
        forgetful.rememberAppStates = true
        #expect(SoundSettings(defaults: d).preference(for: "com.apple.Music").volume == 45)
        forgetful.forgetAppStates()
        #expect(SoundSettings(defaults: d).appStates.isEmpty)
    }

    // MARK: Volume curve

    @Test func gainEndpoints() {
        #expect(VolumeCurve.gain(forPercent: 0) == 0)
        #expect(VolumeCurve.gain(forPercent: 100) == 1)
        #expect(VolumeCurve.gain(forPercent: 150) == 1.5)
        // Out of range clamps; NaN is silence rather than garbage.
        #expect(VolumeCurve.gain(forPercent: -20) == 0)
        #expect(VolumeCurve.gain(forPercent: 400) == 1.5)
        #expect(VolumeCurve.gain(forPercent: .nan) == 0)
        // Perceptual below 100: half the slider is well under half the amplitude.
        #expect(VolumeCurve.gain(forPercent: 50) < 0.5)
        #expect(VolumeCurve.gain(forPercent: 50) > 0)
    }

    @Test func gainMonotonic() {
        var previous: Float = -1
        for tenth in 0...1500 {
            let g = VolumeCurve.gain(forPercent: Double(tenth) / 10)
            #expect(g > previous || (tenth == 0 && g == 0))
            previous = g
        }
    }

    @Test func softClipBounded() {
        // Untouched below the knee, and the knee itself is continuous.
        #expect(SoftClip.apply(0) == 0)
        #expect(SoftClip.apply(0.5) == 0.5)
        #expect(SoftClip.apply(-0.85) == -0.85)
        #expect(abs(SoftClip.apply(SoftClip.knee) - SoftClip.knee) < 1e-6)
        // Never past full scale, whatever goes in, and symmetric.
        for x in stride(from: Float(-40), through: 40, by: 0.01) {
            let y = SoftClip.apply(x)
            #expect(abs(y) <= 1.0)
            #expect(SoftClip.apply(-x) == -y)
        }
        #expect(SoftClip.apply(.infinity) == 1)
        #expect(SoftClip.apply(-.infinity) == -1)
        #expect(SoftClip.apply(.nan) == 0)
        // Monotonic through the knee: louder in is never quieter out.
        var last: Float = -2
        for x in stride(from: Float(0), through: 3, by: 0.001) {
            let y = SoftClip.apply(x)
            #expect(y >= last)
            last = y
        }
    }

    /// Volume changes ramp instead of jumping (no clicks) and land exactly on the target.
    @Test func gainRampConverges() {
        var ramp = GainRamp(gain: 0, rampFrames: 100)
        ramp.target = 1
        var values: [Float] = []
        for _ in 0..<150 { values.append(ramp.next()) }
        #expect(values[0] > 0 && values[0] < 0.05)
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(values[99] == 1)
        #expect(values.last == 1)
        #expect(values.allSatisfy { $0 <= 1 })
        // Down to silence: never undershoots.
        ramp.target = 0
        for _ in 0..<150 { values.append(ramp.next()) }
        #expect(ramp.current == 0)
        #expect(values.allSatisfy { $0 >= 0 })
        // A jump to the boost range takes as many frames per unit of gain.
        ramp.target = 1.5
        var frames = 0
        while ramp.current < 1.5 { _ = ramp.next(); frames += 1 }
        #expect(frames == 150)
        // A non-finite target is ignored.
        ramp.target = .nan
        #expect(ramp.next() == 1.5)
    }

    // MARK: Apps

    /// Helper processes (Chrome renderers, Electron helpers, WebKit's GPU process) count as their app, so
    /// each app gets one pill. Process IDs and responsible apps are from Kevo's Mac.
    @Test func helperGroupsUnderApp() {
        typealias G = AudioAppGrouping
        #expect(G.appBundleID(processBundleID: "com.google.Chrome.helper") == "com.google.Chrome")
        #expect(G.appBundleID(processBundleID: "com.google.Chrome.helper.renderer") == "com.google.Chrome")
        #expect(G.appBundleID(processBundleID: "com.google.Chrome.helper.GPU", responsibleBundleID: "com.google.Chrome") == "com.google.Chrome")
        #expect(G.appBundleID(processBundleID: "com.hnc.Discord.helper.Renderer") == "com.hnc.Discord")
        #expect(G.appBundleID(processBundleID: "com.ringcentral.glip.helper.Plugin") == "com.ringcentral.glip")
        #expect(G.appBundleID(processBundleID: "com.tinyspeck.slackmacgap.helper") == "com.tinyspeck.slackmacgap")
        // WebKit's out-of-process pieces belong to whichever app is responsible for them.
        #expect(G.appBundleID(processBundleID: "com.apple.WebKit.GPU", responsibleBundleID: "com.apple.Safari") == "com.apple.Safari")
        #expect(G.appBundleID(processBundleID: "com.apple.WebKit.WebContent", responsibleBundleID: "com.apple.mail") == "com.apple.mail")
        #expect(G.appBundleID(processBundleID: "com.apple.WebKit.GPU") == "com.apple.WebKit.GPU")
        // A helper whose name doesn't follow the app's ID still goes to its responsible app.
        #expect(G.appBundleID(processBundleID: "com.anysphere.sand.electron-helper", responsibleBundleID: "com.todesktop.cursor") == "com.todesktop.cursor")
        #expect(G.appBundleID(processBundleID: "com.anysphere.sand.electron-helper") == "com.anysphere.sand")
        // Processes without a bundle ID (a command-line player) show as the app that launched them.
        #expect(G.appBundleID(processBundleID: nil, responsibleBundleID: "com.apple.Terminal") == "com.apple.Terminal")
        #expect(G.appBundleID(processBundleID: "", responsibleBundleID: nil) == nil)
        #expect(G.appBundleID(processBundleID: nil, responsibleBundleID: "") == nil)
        // Ordinary apps stay themselves; an app launched from Xcode is still itself.
        #expect(G.appBundleID(processBundleID: "com.spotify.client") == "com.spotify.client")
        #expect(G.appBundleID(processBundleID: "com.spotify.client", responsibleBundleID: "com.spotify.client") == "com.spotify.client")
        #expect(G.appBundleID(processBundleID: "com.example.Game", responsibleBundleID: "com.apple.dt.Xcode", processIsApp: true) == "com.example.Game")
        // "helper" must be a whole component past the vendor part.
        #expect(G.helperParent(of: "com.example.helperkit") == nil)
        #expect(G.helperParent(of: "helper.example.app") == nil)
        #expect(G.helperParent(of: "com.helper") == nil)
        #expect(G.helperParent(of: "com.example.Helper") == "com.example")
    }

    /// The Apps list: what's playing, pinned apps, apps with settings that are running, or every app with
    /// audio when "Show all apps" is on. As in the mockup: playing apps first (by name), then quiet pinned
    /// apps (in pinned order), then the rest (by name).
    @Test func visibleAppsFilterAndOrder() {
        func app(_ id: String, _ name: String, running: Bool = true, playing: Bool = false, listable: Bool = true) -> AudioAppCandidate {
            AudioAppCandidate(bundleID: id, name: name, isRunning: running, isPlaying: playing, isListable: listable)
        }
        let candidates = [
            app("com.apple.Music", "Music", playing: true),
            app("com.google.Chrome", "Google Chrome", playing: true),
            app("com.hnc.Discord", "Discord"),
            app("com.tinyspeck.slackmacgap", "Slack"),
            app("com.ringcentral.glip", "RingCentral"),
            app("com.apple.controlcenter", "Control Center", playing: true, listable: false),
            app("com.kevo.orbit", "Orbit", playing: true),
            app("com.spotify.client", "Spotify", running: false),
        ]
        let quiet = AudioAppList.visible(candidates, pinned: [], customised: [], showAll: false, excluding: ["com.kevo.orbit"])
        #expect(quiet.map(\.name) == ["Google Chrome", "Music"])

        let pinned = AudioAppList.visible(candidates, pinned: ["com.ringcentral.glip", "com.spotify.client"],
                                          customised: ["com.tinyspeck.slackmacgap"], showAll: false, excluding: ["com.kevo.orbit"])
        #expect(pinned.map(\.name) == ["Google Chrome", "Music", "RingCentral", "Spotify", "Slack"])

        let all = AudioAppList.visible(candidates, pinned: ["com.spotify.client"], customised: [], showAll: true, excluding: ["com.kevo.orbit"])
        #expect(all.map(\.name) == ["Google Chrome", "Music", "Spotify", "Discord", "RingCentral", "Slack"])

        // A pinned app that is playing sits with the playing apps.
        let playingPinned = AudioAppList.visible(candidates, pinned: ["com.spotify.client", "com.apple.Music"], customised: [],
                                                 showAll: false, excluding: ["com.kevo.orbit"])
        #expect(playingPinned.map(\.name) == ["Google Chrome", "Music", "Spotify"])

        // Two entries for one app (main process and a helper resolved separately) merge.
        let merged = AudioAppList.visible([app("a", "A"), app("a", "A", playing: true)], pinned: [], customised: [], showAll: false)
        #expect(merged.count == 1)
        #expect(merged.first?.isPlaying == true)
    }

    // MARK: Devices

    /// "Keep preferred mic" switches back only when it is on, a preferred mic is set, the input moved
    /// away from it, and the preferred mic is still connected.
    @Test func preferredMicSwitchBackOnlyWhenAvailable() {
        let available: Set<String> = ["Headset", "BuiltInMicrophoneDevice", "Teams"]
        #expect(PreferredMicPolicy.shouldSwitchBack(currentUID: "Teams", preferredUID: "Headset", availableUIDs: available, keep: true))
        #expect(PreferredMicPolicy.shouldSwitchBack(currentUID: nil, preferredUID: "Headset", availableUIDs: available, keep: true))
        // Unplugged: leave macOS's choice alone.
        #expect(!PreferredMicPolicy.shouldSwitchBack(currentUID: "BuiltInMicrophoneDevice", preferredUID: "Headset",
                                                     availableUIDs: ["BuiltInMicrophoneDevice"], keep: true))
        #expect(!PreferredMicPolicy.shouldSwitchBack(currentUID: "Headset", preferredUID: "Headset", availableUIDs: available, keep: true))
        #expect(!PreferredMicPolicy.shouldSwitchBack(currentUID: "Teams", preferredUID: "Headset", availableUIDs: available, keep: false))
        #expect(!PreferredMicPolicy.shouldSwitchBack(currentUID: "Teams", preferredUID: nil, availableUIDs: available, keep: true))
        #expect(!PreferredMicPolicy.shouldSwitchBack(currentUID: "Teams", preferredUID: "", availableUIDs: available, keep: true))
    }

    /// At most one switch per throttle window; a change that arrives inside it is retried when the window ends
    /// (not dropped, or a second quick switch by macOS would stick).
    @Test func preferredMicThrottleRetriesInsteadOfDropping() {
        let t0 = Date(timeIntervalSinceReferenceDate: 500)
        typealias P = PreferredMicPolicy
        #expect(P.retryDelay(lastSwitch: .distantPast, now: t0) == nil)            // never switched: go now
        #expect(P.retryDelay(lastSwitch: t0, now: t0.addingTimeInterval(P.throttle + 0.01)) == nil)
        let delay = P.retryDelay(lastSwitch: t0, now: t0.addingTimeInterval(0.5))
        #expect(delay != nil)
        #expect(abs((delay ?? 0) - (P.throttle - 0.5)) < 0.001)                   // look again when it ends
        #expect(P.retryDelay(lastSwitch: t0, now: t0) == P.throttle)
    }

    /// Kevo's Mac has two monitors both called "P27u-20": the menus must tell them apart.
    @Test func duplicateDeviceNamesAreNumbered() {
        let devices = [
            AudioDeviceSummary(uid: "K", name: "K272HUL", inputChannels: 0, outputChannels: 2, transport: .displayPort),
            AudioDeviceSummary(uid: "P1", name: "P27u-20", inputChannels: 0, outputChannels: 2, transport: .displayPort),
            AudioDeviceSummary(uid: "P2", name: "P27u-20", inputChannels: 0, outputChannels: 2, transport: .displayPort),
            AudioDeviceSummary(uid: "S", name: "SteelSeries Arctis Nova 5", inputChannels: 1, outputChannels: 2, transport: .usb),
            AudioDeviceSummary(uid: "E", name: "", inputChannels: 0, outputChannels: 2, transport: .unknown),
        ]
        let names = AudioDeviceNaming.displayNames(for: devices)
        #expect(names["K"] == "K272HUL")
        #expect(names["P1"] == "P27u-20")
        #expect(names["P2"] == "P27u-20 (2)")
        #expect(names["S"] == "SteelSeries Arctis Nova 5")
        #expect(names["E"] == "Unnamed device")
    }

    @Test func deviceIconHints() {
        func device(_ name: String, _ transport: AudioTransport, input: Int = 0, output: Int = 2) -> AudioDeviceSummary {
            AudioDeviceSummary(uid: name, name: name, inputChannels: input, outputChannels: output, transport: transport)
        }
        #expect(device("MacBook Pro Speakers", .builtIn).symbol(forInput: false) == "laptopcomputer")
        #expect(device("MacBook Pro Microphone", .builtIn, input: 1, output: 0).symbol(forInput: true) == "laptopcomputer")
        #expect(device("SteelSeries Arctis Nova 5", .usb, input: 1).symbol(forInput: false) == "headphones")
        #expect(device("SteelSeries Arctis Nova 5", .usb, input: 1).symbol(forInput: true) == "headphones")
        #expect(device("USB Audio CODEC", .usb).symbol(forInput: false) == "hifispeaker")
        #expect(device("Yeti Stereo Microphone", .usb, input: 2, output: 0).symbol(forInput: true) == "mic")
        #expect(device("P27u-20", .displayPort).symbol(forInput: false) == "display")
        #expect(device("LG TV", .hdmi).symbol(forInput: false) == "display")
        #expect(device("Kevo's AirPods Pro", .bluetooth).symbol(forInput: false) == "airpodspro")
        #expect(device("AirPods Max", .bluetooth).symbol(forInput: false) == "airpodsmax")
        #expect(device("AirPods", .bluetooth).symbol(forInput: false) == "airpods")
        #expect(device("WH-1000XM5", .bluetooth).symbol(forInput: false) == "headphones")
        #expect(device("Microsoft Teams Audio", .virtual, input: 1, output: 1).symbol(forInput: false) == "waveform")
        #expect(device("Living Room", .airPlay).symbol(forInput: false) == "airplayaudio")
        #expect(device("Multi-Output Device", .aggregate).symbol(forInput: false) == "square.stack.3d.up")
        // Transport codes are Core Audio's four-character codes.
        #expect(AudioTransport(fourCC: 0x626C_746E) == .builtIn)      // 'bltn'
        #expect(AudioTransport(fourCC: 0x7573_6220) == .usb)          // 'usb '
        #expect(AudioTransport(fourCC: 0x6470_7274) == .displayPort)  // 'dprt'
        #expect(AudioTransport(fourCC: 0x7669_7274) == .virtual)      // 'virt'
        #expect(AudioTransport(fourCC: 0x626C_7565) == .bluetooth)    // 'blue'
        #expect(AudioTransport(fourCC: 0x6772_7570) == .aggregate)    // 'grup'
        #expect(AudioTransport(fourCC: 0) == .unknown)
        #expect(device("x", .usb, input: 1, output: 0).hasInput && !device("x", .usb, input: 1, output: 0).hasOutput)
    }

    /// A volume drag changes the state live (the engine follows it) but writes defaults only when it ends.
    @Test func settingsDeferWritesDuringDrag() {
        let (d, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let s = SoundSettings(defaults: d)
        var published = 0
        let watch = s.$appStates.dropFirst().sink { _ in published += 1 }
        for volume in stride(from: 99.0, through: 80, by: -1) {
            s.setPreference(AppAudioPreference(volume: volume), for: "com.apple.Music", persist: false)
        }
        #expect(published == 20)                              // every tick is live
        #expect(s.preference(for: "com.apple.Music").volume == 80)
        #expect(d.data(forKey: "sound.appStates") == nil)     // but nothing was written yet
        s.persistAppStates()
        #expect(SoundSettings(defaults: d).preference(for: "com.apple.Music").volume == 80)
        // Ordinary changes (mute, output, reset) still write at once.
        s.setPreference(AppAudioPreference(volume: 80, muted: true), for: "com.apple.Music")
        #expect(SoundSettings(defaults: d).preference(for: "com.apple.Music").muted)
        // With "remember" off, finishing a drag writes nothing.
        s.rememberAppStates = false
        s.setPreference(AppAudioPreference(volume: 30), for: "com.apple.Music", persist: false)
        s.persistAppStates()
        #expect(d.data(forKey: "sound.appStates") == nil)
        watch.cancel()
    }

    @Test func settingsRejectBadData() throws {
        let (d, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        d.set(Data("junk".utf8), forKey: "sound.appStates")
        #expect(SoundSettings(defaults: d).appStates.isEmpty)
        // Out-of-range volumes are clamped to 0…150 on read and on write.
        let json = #"{"com.example.loud":{"volume":300,"muted":false},"com.example.neg":{"volume":-4,"muted":false}}"#
        d.set(Data(json.utf8), forKey: "sound.appStates")
        let s = SoundSettings(defaults: d)
        #expect(s.preference(for: "com.example.loud").volume == 150)
        #expect(s.preference(for: "com.example.neg").volume == 0)
        #expect(AppAudioPreference(volume: 151).volume == 150)
        #expect(AppAudioPreference(volume: .nan).volume == 100)
        var p = AppAudioPreference()
        p.volume = -1
        #expect(p.volume == 0)
        #expect(AppAudioPreference.unity.isDefault)
        #expect(!AppAudioPreference(volume: 99).isDefault)
        #expect(!AppAudioPreference(muted: true).isDefault)
        #expect(!AppAudioPreference(outputUID: "x").isDefault)
    }
}

extension SoundTests {
    /// The shared mic mute (Review Focus 6): Orbit remembers what it changed and puts back exactly that,
    /// never "restoring" a mute it did not apply.
    @Suite struct MicMuteStateTests {
        let headset = MicDeviceReading(deviceUID: "Headset", canSetMute: true, isMuted: false, canSetVolume: true, volume: 0.8)

        @Test func restoresPreviousState() {
            var state = MicMuteState()
            #expect(!state.isMuted)
            let r1 = state.mute(headset); #expect(r1 == [.setMute(deviceUID: "Headset", muted: true)])
            #expect(state.isMuted)
            #expect(state.deviceUID == "Headset")
            // Muting again changes nothing and keeps the first record.
            let r2 = state.mute(headset); #expect(r2 == [])
            let r3 = state.restore(); #expect(r3 == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(!state.isMuted)
            // Nothing left to restore (a second quit, or unmute after unmute).
            let r4 = state.restore(); #expect(r4 == [])
        }

        /// A device without a mute control is muted by turning its input volume to 0, and the volume it had
        /// comes back on unmute.
        @Test func volumeFallbackRestoresVolume() {
            var state = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            let r5 = state.mute(noMute); #expect(r5 == [.setVolume(deviceUID: "USB", volume: 0)])
            #expect(state.isMuted)
            let r6 = state.restore(); #expect(r6 == [.setVolume(deviceUID: "USB", volume: 0.62)])
            #expect(!state.isMuted)
            // A mic that has neither control can't be muted.
            let fixed = MicDeviceReading(deviceUID: "Fixed", canSetMute: false, isMuted: false, canSetVolume: false, volume: nil)
            let r7 = state.mute(fixed); #expect(r7 == nil)
            #expect(!state.isMuted)
            let r8 = state.mute(MicDeviceReading(deviceUID: "X", canSetMute: false, isMuted: false, canSetVolume: true, volume: nil)); #expect(r8 == nil)
        }

        /// The mic was already muted (by the user, in Sound settings or on the headset) when Orbit's mute was
        /// pressed: Orbit's unmute and quit leave it muted.
        @Test func doesNotUnmuteUserMute() {
            var state = MicMuteState()
            var userMuted = headset
            userMuted.isMuted = true
            let r9 = state.mute(userMuted); #expect(r9 == [])
            #expect(state.isMuted)
            let r10 = state.restore(); #expect(r10 == [])
            #expect(!state.isMuted)
            // Same for a volume the user had at zero.
            let zero = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0)
            let r11 = state.mute(zero); #expect(r11 == [])
            let r12 = state.restore(); #expect(r12 == [])
        }

        /// macOS switched the input while muted: the old mic is put back (or kept on record if it's gone), the
        /// new one is muted.
        @Test func followsInputChange() {
            var state = MicMuteState()
            _ = state.mute(headset)
            let builtIn = MicDeviceReading(deviceUID: "BuiltIn", canSetMute: true, isMuted: false, canSetVolume: true, volume: 1)
            // Old device still there: write its restore, commit, mute the new one.
            let r13 = state.restoreActions(); #expect(r13 == [.setMute(deviceUID: "Headset", muted: false)])
            state.commitRestore()
            let r14 = state.mute(builtIn); #expect(r14 == [.setMute(deviceUID: "BuiltIn", muted: true)])
            #expect(state.deviceUID == "BuiltIn")
            // Old device unplugged: its record is set aside, the mute moves on.
            state.setAside()
            #expect(!state.isMuted)
            #expect(state.pending.map(\.deviceUID) == ["BuiltIn"])
            let r15 = state.mute(headset); #expect(r15 == [.setMute(deviceUID: "Headset", muted: true)])
            #expect(state.deviceUID == "Headset")
            #expect(state.hasRecord)
            // To a device Orbit can't mute: the mute ends; nothing pretends otherwise.
            let fixed = MicDeviceReading(deviceUID: "Fixed", canSetMute: false, isMuted: false, canSetVolume: false, volume: nil)
            state.commitRestore()
            let r16 = state.mute(fixed); #expect(r16 == nil)
            #expect(!state.isMuted)
        }

        /// I1: an unmute whose write fails keeps everything: the record (to retry, and to survive a quit), the
        /// mute itself. Only a successful write forgets it.
        @Test func unmuteFailureKeepsRecord() throws {
            var state = MicMuteState()
            _ = state.mute(headset)
            let first = state.restoreActions()
            let again = state.restoreActions()
            #expect(first == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(again == first)                                  // asking doesn't forget
            #expect(state.isMuted)
            #expect(state.hasRecord)
            let kept = try JSONDecoder().decode(MicMuteState.self, from: JSONEncoder().encode(state))
            #expect(kept == state)                                   // what a failed quit leaves for next launch
            let fromLaunch = MicMuteState.fromPreviousRun(kept)
            var stillMuted = headset
            stillMuted.isMuted = true
            let work = fromLaunch.pendingWork { $0 == "Headset" ? stillMuted : nil }
            #expect(work.map(\.deviceUID) == ["Headset"])
            #expect(work.first?.actions == [.setMute(deviceUID: "Headset", muted: false)])
            state.commitRestore()
            #expect(!state.isMuted)
            #expect(!state.hasRecord)
            #expect(state.restoreActions() == [])
        }

        /// M3: the muted mic is unplugged. Its record is kept until it comes back, then it is unmuted, as long as
        /// it is still as Orbit left it.
        @Test func deviceGoneKeepsRecordUntilItReturns() {
            var state = MicMuteState()
            _ = state.mute(headset)
            state.setAside()
            #expect(!state.isMuted)
            #expect(state.hasRecord)
            #expect(state.pendingWork { _ in nil }.isEmpty)          // still gone: nothing to do, keep waiting
            var backMuted = headset
            backMuted.isMuted = true
            let work = state.pendingWork { $0 == "Headset" ? backMuted : nil }
            #expect(work.count == 1)
            #expect(work.first?.actions == [.setMute(deviceUID: "Headset", muted: false)])
            state.resolvePending(deviceUID: "Headset")
            #expect(!state.hasRecord)
            // Back already unmuted (by the user, or by the device itself): resolved with nothing to write.
            _ = state.mute(headset)
            state.setAside()
            let unmuted = state.pendingWork { $0 == "Headset" ? headset : nil }
            #expect(unmuted.first?.actions == [])
            // A volume-muted device back at 0 gets its volume back.
            var volumeState = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            _ = volumeState.mute(noMute)
            volumeState.setAside()
            var atZero = noMute
            atZero.volume = 0
            #expect(volumeState.pendingWork { _ in atZero }.first?.actions == [.setVolume(deviceUID: "USB", volume: 0.62)])
        }

        /// The default input comes back to a mic that is still on record while Orbit's mute is on: muting it again
        /// keeps its original state, so the later unmute really unmutes it.
        @Test func remutingAPendingDeviceKeepsItsOriginalState() {
            var state = MicMuteState()
            _ = state.mute(headset)                                  // headset was unmuted before Orbit
            state.setAside()
            var backMuted = headset
            backMuted.isMuted = true
            let r = state.mute(backMuted)
            #expect(r == [])                                         // already muted
            #expect(state.pending.isEmpty)
            #expect(state.restoreActions() == [.setMute(deviceUID: "Headset", muted: false)])
        }

        /// N1: a write can take effect asynchronously, so a reading taken right after Orbit's own mute may still say
        /// "unmuted". That must not be taken for the user unmuting elsewhere: until a reading shows Orbit's write
        /// (or `timeout` passes) it is projected to what the write will leave and not trusted.
        @Test func ownWriteIsNotMistakenForOutsideUnmute() {
            let t0 = ContinuousClock.now
            var state = MicMuteState()
            var guardian = MicWriteConfirmation()
            let r0 = guardian.review(headset, now: t0)
            #expect(r0.trusted && r0.reading == headset)                         // nothing written: no wait
            let actions = state.mute(headset) ?? []
            guardian.wrote(actions, at: t0)
            #expect(guardian.isWaiting)
            // Still reads unmuted a moment later: shown as muted, not trusted, Orbit's mute stays.
            let r1 = guardian.review(headset, now: t0 + .seconds(0.02))
            #expect(!r1.trusted)
            #expect(r1.reading.isMuted)
            #expect(state.presentation(for: r1.reading) == .mutedByOrbit)
            #expect(state.isMuted)
            // The write lands: confirmed, the wait ends.
            var muted = headset
            muted.isMuted = true
            let r2 = guardian.review(muted, now: t0 + .seconds(0.05))
            #expect(r2.trusted)
            #expect(!guardian.isWaiting)
            let stillMuted = state.deviceChanged(r2.reading)
            #expect(stillMuted)
            // Later the user really unmutes elsewhere: trusted, Orbit lets go.
            let r3 = guardian.review(headset, now: t0 + .seconds(9))
            #expect(r3.trusted)
            let after = state.deviceChanged(r3.reading)
            #expect(!after)
            // A write that never shows up: after the timeout the reading counts again (the mute didn't take).
            let again = state.mute(headset) ?? []
            guardian.wrote(again, at: t0)
            let r4 = guardian.review(headset, now: t0 + MicWriteConfirmation.timeout - .milliseconds(100))
            #expect(!r4.trusted)
            let r5 = guardian.review(headset, now: t0 + MicWriteConfirmation.timeout)
            #expect(r5.trusted && r5.reading == headset)
            #expect(!guardian.isWaiting)
            // Volume-muted: projected to 0 until the volume reads 0.
            var volumeState = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            guardian.wrote(volumeState.mute(noMute) ?? [], at: t0)
            let r6 = guardian.review(noMute, now: t0 + .seconds(0.01))
            #expect(!r6.trusted && r6.reading.volume == 0)
            var atZero = noMute
            atZero.volume = 0
            let r7 = guardian.review(atZero, now: t0 + .seconds(0.02))
            #expect(r7.trusted)
            #expect(volumeState.reflects(atZero))
            #expect(!volumeState.reflects(noMute))
            // A reading of another device says nothing about the write: taken as it is, the wait goes on.
            guardian.wrote([.setMute(deviceUID: "Headset", muted: true)], at: t0)
            var other = headset
            other.deviceUID = "Other"
            let r8 = guardian.review(other, now: t0 + .seconds(0.01))
            #expect(r8.trusted && r8.reading == other)
            #expect(guardian.isWaiting)
            // Writing nothing waits for nothing, and doesn't end the wait for a write still landing.
            guardian.wrote([], at: t0)
            #expect(guardian.isWaiting)
            var idle = MicWriteConfirmation()
            idle.wrote([], at: t0)
            #expect(!idle.isWaiting)
        }

        /// R3: right after Orbit's own unmute the device may still read muted. It must not flash "Muted outside Orbit",
        /// and a quick second press must mute (not unmute again): the reading is projected to unmuted until the
        /// unmute shows, or the timeout passes (then the device's own state shows: the unmute didn't take).
        @Test func ownUnmuteDoesNotFlashOutsideMute() {
            let t0 = ContinuousClock.now
            var state = MicMuteState()
            _ = state.mute(headset)
            let undo = state.restoreActions()
            state.commitRestore()
            var guardian = MicWriteConfirmation()
            guardian.wrote(undo, at: t0)
            var stillMuted = headset
            stillMuted.isMuted = true
            let r1 = guardian.review(stillMuted, now: t0 + .seconds(0.02))
            #expect(!r1.trusted)
            #expect(!r1.reading.isMuted)
            #expect(state.presentation(for: r1.reading) == .unmuted)            // not .mutedElsewhere
            let r2 = guardian.review(headset, now: t0 + .seconds(0.05))  // the unmute landed
            #expect(r2.trusted && !guardian.isWaiting)
            // An unmute that never lands: after the timeout the device's own (muted) state shows.
            guardian.wrote(undo, at: t0)
            let r3 = guardian.review(stillMuted, now: t0 + MicWriteConfirmation.timeout)
            #expect(r3.trusted && r3.reading.isMuted)
            #expect(state.presentation(for: r3.reading) == .mutedElsewhere)
            // Unmuting a mute made elsewhere (a direct user action) is covered the same way.
            guardian.wrote(MicMuteState.directUnmute(stillMuted), at: t0)
            let r4 = guardian.review(stillMuted, now: t0 + .seconds(0.01))
            #expect(!r4.trusted && !r4.reading.isMuted)
            // A volume restore is projected to the restored volume.
            let atZero = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0)
            guardian.wrote([.setVolume(deviceUID: "USB", volume: 0.62)], at: t0)
            let r5 = guardian.review(atZero, now: t0 + .seconds(0.01))
            #expect(!r5.trusted && r5.reading.volume == 0.62)
        }

        /// A reading ends a write's wait only by showing that write's own value, or once the write has timed out (it
        /// evidently didn't take). A stale reading that happens to match some other value Orbit might want confirms
        /// nothing, and writing nothing keeps a write still landing waiting. An undo that times out without showing hands
        /// back the mute it was undoing, so the model can tell whether Orbit's mute is still in effect.
        @Test func aReadingConfirmsOnlyTheWritesOwnValue() {
            let t0 = ContinuousClock.now
            func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
            var muted = headset
            muted.isMuted = true
            let record = MicMuteState.Applied(deviceUID: "Headset", method: .muteFlag(wasMuted: false))
            var guardian = MicWriteConfirmation()
            guardian.wrote([.setMute(deviceUID: "Headset", muted: false)], undoing: record, at: t0)
            #expect(guardian.isWaiting(on: "Headset") && !guardian.isWaiting(on: "BuiltIn"))
            #expect(guardian.nextDeadline == t0 + MicWriteConfirmation.timeout)
            // Still muted: shown unmuted, not trusted, nothing settled.
            let stale = guardian.review(muted, now: at(0.01))
            #expect(!stale.trusted && !stale.settled && !stale.reading.isMuted)
            guardian.wrote([], at: at(0.02))
            #expect(guardian.isWaiting(on: "Headset"))
            // The unmute shows: settled, trusted, nothing timed out.
            let shown = guardian.review(headset, now: at(0.03))
            #expect(shown.trusted && shown.settled && shown.timedOut.isEmpty && shown.undosNotShown.isEmpty)
            #expect(!guardian.isWaiting && guardian.nextDeadline == nil)
            // An undo that never shows: once timed out the reading counts as it is, and the mute it undid comes back.
            guardian.wrote([.setMute(deviceUID: "Headset", muted: false)], undoing: record, at: at(1))
            let early = guardian.review(muted, now: at(1) + MicWriteConfirmation.timeout - .milliseconds(1))
            #expect(!early.trusted)
            let late = guardian.review(muted, now: at(1) + MicWriteConfirmation.timeout)
            #expect(late.trusted && late.settled && late.reading == muted)
            #expect(late.timedOut == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(late.undosNotShown == [record])
            // A device that went away: its writes are dropped, handing back what they were undoing.
            guardian.wrote([.setMute(deviceUID: "Headset", muted: false)], undoing: record, at: at(5))
            #expect(guardian.projected(muted) == headset)
            #expect(guardian.forget(deviceUID: "Headset") == [record])
            #expect(!guardian.isWaiting)
            // The reading as actions will leave it; actions for another device change nothing.
            #expect(headset.applying([.setMute(deviceUID: "Headset", muted: true), .setVolume(deviceUID: "Other", volume: 0)]) == muted)
        }

        /// F4: each device's writes wait on their own: a write to one device never ends the wait for another (the old mic
        /// put back as the input moves, the new one muted). The whole flip-back is replayed in
        /// `inputFlipBackWhileMutedWaitsForBothMics`.
        @Test func writesToSeveralDevicesWaitApart() {
            let t0 = ContinuousClock.now
            func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
            var mutedHeadset = headset
            mutedHeadset.isMuted = true
            let builtIn = MicDeviceReading(deviceUID: "BuiltIn", canSetMute: true, isMuted: false, canSetVolume: true, volume: 1)
            var mutedBuiltIn = builtIn
            mutedBuiltIn.isMuted = true
            var guardian = MicWriteConfirmation()
            guardian.wrote([.setMute(deviceUID: "Headset", muted: false)], at: t0)
            guardian.wrote([.setMute(deviceUID: "BuiltIn", muted: true)], at: t0)
            let builtInStale = guardian.review(builtIn, now: at(0.01))
            #expect(!builtInStale.trusted && builtInStale.reading.isMuted)
            let headsetStale = guardian.review(mutedHeadset, now: at(0.02))
            #expect(!headsetStale.trusted && !headsetStale.reading.isMuted)
            // One device confirming leaves the other waiting.
            let builtInLanded = guardian.review(mutedBuiltIn, now: at(0.04))
            #expect(builtInLanded.trusted)
            #expect(guardian.isWaiting)
            let headsetLanded = guardian.review(headset, now: at(0.05))
            #expect(headsetLanded.trusted)
            #expect(!guardian.isWaiting)
            // A later write to the same control replaces the earlier one: the device will show the later one.
            guardian.wrote([.setMute(deviceUID: "Headset", muted: true)], at: at(1))
            guardian.wrote([.setMute(deviceUID: "Headset", muted: false)], at: at(1.01))
            let superseded = guardian.review(mutedHeadset, now: at(1.02))
            #expect(!superseded.trusted && !superseded.reading.isMuted)
            // Each write has its own timeout. A wait ends only with a reading of its own device (`MicMuteModel` reads
            // every mic with a write waiting, and forgets one that is gone once its writes have timed out).
            guardian.wrote([.setMute(deviceUID: "BuiltIn", muted: true)], at: at(2.5))
            let headsetExpired = guardian.review(mutedHeadset, now: at(1.01) + MicWriteConfirmation.timeout)
            #expect(headsetExpired.trusted && headsetExpired.reading.isMuted)
            #expect(headsetExpired.timedOut == [.setMute(deviceUID: "Headset", muted: false)])
            let builtInWaits = guardian.review(builtIn, now: at(1.01) + MicWriteConfirmation.timeout)
            #expect(!builtInWaits.trusted)
            let other = MicDeviceReading(deviceUID: "Other", canSetMute: true, isMuted: false, canSetVolume: false, volume: nil)
            _ = guardian.review(other, now: at(2.5) + MicWriteConfirmation.timeout)
            #expect(guardian.waitingDevices == ["BuiltIn"])                     // another mic's reading says nothing of it
            #expect(!guardian.hasTimedOut(deviceUID: "BuiltIn", now: at(2.5) + MicWriteConfirmation.timeout - .milliseconds(1)))
            #expect(guardian.hasTimedOut(deviceUID: "BuiltIn", now: at(2.5) + MicWriteConfirmation.timeout))
            #expect(guardian.forget(deviceUID: "BuiltIn").isEmpty)
            #expect(!guardian.isWaiting)
        }

        /// M2: the mic's live state, whoever muted it. A mute made outside Orbit shows as such; a direct unmute
        /// clears it, and Orbit never "restores" it on its own.
        @Test func liveStateShowsOutsideMute() {
            var state = MicMuteState()
            var mutedElsewhere = headset
            mutedElsewhere.isMuted = true
            let fixed = MicDeviceReading(deviceUID: "Fixed", canSetMute: false, isMuted: false, canSetVolume: false, volume: nil)
            #expect(state.presentation(for: headset) == .unmuted)
            #expect(state.presentation(for: mutedElsewhere) == .mutedElsewhere)
            #expect(state.presentation(for: fixed) == .unavailable)
            #expect(state.presentation(for: nil) == .unavailable)
            #expect(MicMuteState.directUnmute(mutedElsewhere) == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(MicMuteState.directUnmute(headset) == [])
            #expect(state.restoreActions() == [])                    // nothing of Orbit's to restore
            _ = state.mute(headset)
            #expect(state.presentation(for: mutedElsewhere) == .mutedByOrbit)
            #expect(state.presentation(for: nil) == .mutedByOrbit)   // still in effect while unreadable
            // Volume-muted by Orbit: muted, although the device has no mute control.
            var volumeState = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            _ = volumeState.mute(noMute)
            var atZero = noMute
            atZero.volume = 0
            #expect(volumeState.presentation(for: atZero) == .mutedByOrbit)
            #expect(MicMuteState().presentation(for: atZero) == .unmuted)
        }

        /// The user unmuted the mic outside Orbit: Orbit stops holding the mute and has nothing to restore.
        @Test func externalUnmuteClearsState() {
            var state = MicMuteState()
            _ = state.mute(headset)
            var stillMuted = headset
            stillMuted.isMuted = true
            let r18 = state.deviceChanged(stillMuted); #expect(r18)
            var other = headset
            other.deviceUID = "Other"
            let r19 = state.deviceChanged(other); #expect(r19)            // another device: ignored
            let r20 = state.deviceChanged(headset); #expect(!r20)         // unmuted elsewhere
            #expect(!state.isMuted)
            let r21 = state.restore(); #expect(r21 == [])

            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            _ = state.mute(noMute)
            var atZero = noMute
            atZero.volume = 0
            let r22 = state.deviceChanged(atZero); #expect(r22)
            var raised = noMute
            raised.volume = 0.4
            let r23 = state.deviceChanged(raised); #expect(!r23)
            let r24 = state.restore(); #expect(r24 == [])
        }

        /// After a crash, the next launch undoes a mute the previous run left, but only while the mic is still
        /// exactly as Orbit left it.
        @Test func crashRecoveryRestoresOnlyIfUnchanged() throws {
            var state = MicMuteState()
            _ = state.mute(headset)
            let record = try JSONDecoder().decode(MicMuteState.self, from: JSONEncoder().encode(state))
            #expect(record == state)
            let launch = MicMuteState.fromPreviousRun(record)
            #expect(!launch.isMuted)                                 // nothing is "in effect" for the new run
            #expect(launch.pending.map(\.deviceUID) == ["Headset"])
            var mutedNow = headset
            mutedNow.isMuted = true
            #expect(launch.pendingWork { _ in mutedNow }.first?.actions == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(launch.pendingWork { _ in headset }.first?.actions == [])     // the user unmuted it: resolve
            #expect(launch.pendingWork { _ in nil }.isEmpty)                      // not connected: keep the record
            #expect(MicMuteState.fromPreviousRun(MicMuteState()).pendingWork { _ in mutedNow }.isEmpty)

            var volumeState = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            _ = volumeState.mute(noMute)
            var atZero = noMute
            atZero.volume = 0
            let volumeLaunch = MicMuteState.fromPreviousRun(volumeState)
            #expect(volumeLaunch.pendingWork { _ in atZero }.first?.actions == [.setVolume(deviceUID: "USB", volume: 0.62)])
            #expect(volumeLaunch.pendingWork { _ in noMute }.first?.actions == [])
            // A user mute that was already there before Orbit is never undone.
            var userMuted = MicMuteState()
            _ = userMuted.mute(mutedNow)
            #expect(MicMuteState.fromPreviousRun(userMuted).pendingWork { _ in mutedNow }.first?.actions == [])
            // Records written before `pending` existed still decode.
            let legacy = #"{"applied":{"deviceUID":"Headset","method":{"muteFlag":{"wasMuted":false}}}}"#
            let decoded = try JSONDecoder().decode(MicMuteState.self, from: Data(legacy.utf8))
            #expect(decoded.deviceUID == "Headset")
            #expect(decoded.pending.isEmpty)
        }
    }
}

extension SoundTests {
    /// When an app gets a process tap (Review Focus 1): only when it is not at 100 %, unmuted, on the
    /// output it would use anyway, and only when there is a device to play on.
    @Suite struct TapPlanTests {
        @Test func noTapAtUnityOnDefaultOutput() {
            let plan = TapPlan(preference: .unity, defaultOutputUID: "Headset")
            #expect(!plan.needsTap)
            #expect(plan.destinationUID == "Headset")
            #expect(plan.gain == 1)
            #expect(!TapPlan(preference: .unity, defaultOutputUID: "Headset", availableOutputUIDs: ["Headset", "Speakers"]).needsTap)
            #expect(!TapPlan(preference: .unity, defaultOutputUID: nil).needsTap)
            // A stored 100 % from an old run is still unity.
            #expect(!TapPlan(preference: AppAudioPreference(volume: 100, muted: false, outputUID: nil), defaultOutputUID: "Headset").needsTap)
        }

        @Test func tapWhenBoosted() {
            let boosted = TapPlan(preference: AppAudioPreference(volume: 130), defaultOutputUID: "Headset")
            #expect(boosted.needsTap)
            #expect(boosted.destinationUID == "Headset")
            #expect(abs(boosted.gain - 1.3) < 1e-6)
            #expect(boosted.isBoosted)
            let quieter = TapPlan(preference: AppAudioPreference(volume: 40), defaultOutputUID: "Headset")
            #expect(quieter.needsTap)
            #expect(abs(quieter.gain - 0.16) < 1e-6)
            #expect(!quieter.isBoosted)
            let muted = TapPlan(preference: AppAudioPreference(volume: 130, muted: true), defaultOutputUID: "Headset")
            #expect(muted.needsTap)
            #expect(muted.gain == 0)
            #expect(muted.muted)
        }

        @Test func tapWhenRoutedElsewhere() {
            let plan = TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: "Headset",
                               availableOutputUIDs: ["Headset", "Speakers"])
            #expect(plan.needsTap)
            #expect(plan.destinationUID == "Speakers")
            #expect(plan.gain == 1)
            #expect(plan.isRoutedAway)
            #expect(!plan.routeUnavailable)
            // Without a device list the route is taken at its word.
            #expect(TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: "Headset").needsTap)
        }

        @Test func noTapWhenRoutedToCurrentDefault() {
            let plan = TapPlan(preference: AppAudioPreference(outputUID: "Headset"), defaultOutputUID: "Headset",
                               availableOutputUIDs: ["Headset", "Speakers"])
            #expect(!plan.needsTap)
            #expect(plan.destinationUID == "Headset")
            #expect(!plan.isRoutedAway)
            // ...but a volume change on top of it still needs one, to the same device.
            let quieter = TapPlan(preference: AppAudioPreference(volume: 70, outputUID: "Headset"), defaultOutputUID: "Headset")
            #expect(quieter.needsTap)
            #expect(quieter.destinationUID == "Headset")
        }

        /// A routed device that is unplugged falls back to the system output instead of building an
        /// aggregate around a missing device.
        @Test func routedDeviceMissingFallsBack() {
            let plan = TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: "Headset",
                               availableOutputUIDs: ["Headset"])
            #expect(!plan.needsTap)
            #expect(plan.destinationUID == "Headset")
            #expect(plan.routeUnavailable)
            let quieter = TapPlan(preference: AppAudioPreference(volume: 50, outputUID: "Speakers"), defaultOutputUID: "Headset",
                                  availableOutputUIDs: ["Headset"])
            #expect(quieter.needsTap)
            #expect(quieter.destinationUID == "Headset")
        }

        /// "Same as Output" leaves an app where it plays on its own: an app that picked a device in its own
        /// settings (Discord on the headset while the system plays on the speakers) keeps it, so a volume
        /// change never moves it.
        @Test func sameAsOutputFollowsTheAppsOwnDevice() {
            let available: Set<String> = ["Headset", "Speakers", "Display"]
            #expect(TapPlan.followedOutput(appDeviceUIDs: ["Headset"], systemOutputUID: "Speakers", availableOutputUIDs: available) == "Headset")
            #expect(TapPlan.followedOutput(appDeviceUIDs: ["Headset", "Headset"], systemOutputUID: "Speakers", availableOutputUIDs: available) == "Headset")
            // Nothing reported yet (the app never played this run), playing on several, or on something not in the
            // list: the system output. (While an app is merely idle, `AppOutputMemory` keeps its last device.)
            #expect(TapPlan.followedOutput(appDeviceUIDs: [], systemOutputUID: "Speakers", availableOutputUIDs: available) == "Speakers")
            #expect(TapPlan.followedOutput(appDeviceUIDs: ["Headset", "Display"], systemOutputUID: "Speakers", availableOutputUIDs: available) == "Speakers")
            #expect(TapPlan.followedOutput(appDeviceUIDs: ["com.kevo.orbit.tap.1"], systemOutputUID: "Speakers", availableOutputUIDs: available) == "Speakers")
            #expect(TapPlan.followedOutput(appDeviceUIDs: [], systemOutputUID: nil, availableOutputUIDs: available) == nil)

            // Plugged into the plan: the app's own device counts as its output.
            let own = TapPlan.followedOutput(appDeviceUIDs: ["Headset"], systemOutputUID: "Speakers", availableOutputUIDs: available)
            let quieter = TapPlan(preference: AppAudioPreference(volume: 50), defaultOutputUID: own, availableOutputUIDs: available)
            #expect(quieter.destinationUID == "Headset")
            #expect(!TapPlan(preference: AppAudioPreference(outputUID: "Headset"), defaultOutputUID: own, availableOutputUIDs: available).needsTap)
        }

        /// Core Audio reports no devices for an idle process. Discord on the headset going quiet between pings
        /// must stay planned on the headset, not flip to the speakers and back on every ping.
        @Test func sameAsOutputSurvivesIdle() {
            let available: Set<String> = ["Headset", "Speakers"]
            var memory = AppOutputMemory()
            func plan(_ devices: [String], running: Bool = true) -> TapPlan {
                let seen = memory.observe(app: "com.hnc.Discord", deviceUIDs: devices, hasProcesses: running)
                let own = TapPlan.followedOutput(appDeviceUIDs: seen, systemOutputUID: "Speakers", availableOutputUIDs: available)
                return TapPlan(preference: AppAudioPreference(volume: 50), defaultOutputUID: own, availableOutputUIDs: available)
            }
            #expect(plan(["Headset"]).destinationUID == "Headset")     // playing
            #expect(plan([]).destinationUID == "Headset")              // idle: still the headset
            #expect(plan(["Headset"]).destinationUID == "Headset")     // playing again: no change
            #expect(memory.devices(for: "com.hnc.Discord") == ["Headset"])
            // Routed to its own device while idle: still no tap.
            let seen = memory.observe(app: "com.hnc.Discord", deviceUIDs: [], hasProcesses: true)
            let own = TapPlan.followedOutput(appDeviceUIDs: seen, systemOutputUID: "Speakers", availableOutputUIDs: available)
            #expect(!TapPlan(preference: AppAudioPreference(outputUID: "Headset"), defaultOutputUID: own, availableOutputUIDs: available).needsTap)
            // The app switches device in its own settings: follow it.
            #expect(plan(["Speakers"]).destinationUID == "Speakers")
            #expect(plan([]).destinationUID == "Speakers")
            // Its processes are gone: forgotten, back to the system output next time.
            #expect(plan([], running: false).destinationUID == "Speakers")
            #expect(memory.devices(for: "com.hnc.Discord").isEmpty)
            _ = memory.observe(app: "com.hnc.Discord", deviceUIDs: ["Headset"], hasProcesses: true)
            _ = memory.observe(app: "com.google.Chrome", deviceUIDs: ["Speakers"], hasProcesses: true)
            memory.forgetApps(notIn: ["com.google.Chrome"])
            #expect(memory.devices(for: "com.hnc.Discord").isEmpty)
            #expect(memory.devices(for: "com.google.Chrome") == ["Speakers"])
        }

        /// N4: an idle app that follows the system output had the old output remembered. When the system output
        /// changes, that memory goes, so the app follows the switch; an app on its own device keeps it.
        @Test func systemOutputChangeDropsFollowers() {
            var memory = AppOutputMemory()
            _ = memory.observe(app: "com.google.Chrome", deviceUIDs: ["Headset"], hasProcesses: true)   // follows the system
            _ = memory.observe(app: "com.hnc.Discord", deviceUIDs: ["Speakers"], hasProcesses: true)    // its own choice
            memory.systemOutputChanged(from: "Headset")
            #expect(memory.devices(for: "com.google.Chrome").isEmpty)
            #expect(memory.devices(for: "com.hnc.Discord") == ["Speakers"])
            let chrome = memory.observe(app: "com.google.Chrome", deviceUIDs: [], hasProcesses: true)  // still idle
            #expect(TapPlan.followedOutput(appDeviceUIDs: chrome, systemOutputUID: "Speakers",
                                           availableOutputUIDs: ["Headset", "Speakers"]) == "Speakers")
            memory.systemOutputChanged(from: nil)                     // no previous output: nothing to drop
            #expect(memory.devices(for: "com.hnc.Discord") == ["Speakers"])
        }

        /// A tap's aggregate stops doing IO once its app has been quiet for `idleDelay`, and only once per quiet
        /// spell; playing again re-arms it (the aggregate restarts itself with the app's next audio).
        @Test func tapPausesAfterIdleDelay() {
            let t0 = ContinuousClock.now
            func at(_ seconds: Double) -> ContinuousClock.Instant { t0 + .seconds(seconds) }
            var activity = TapActivity(now: t0, isPlaying: true)
            #expect(activity.update(isPlaying: true, now: at(1)) == nil)
            #expect(activity.nextCheck() == nil)                       // playing: nothing to wait for
            #expect(activity.update(isPlaying: false, now: at(10)) == nil)
            #expect(activity.nextCheck() == at(10) + TapActivity.idleDelay)
            #expect(activity.update(isPlaying: false, now: at(10) + TapActivity.idleDelay - .milliseconds(100)) == nil)
            #expect(activity.update(isPlaying: false, now: at(10) + TapActivity.idleDelay) == .pause)
            #expect(activity.isPaused)
            #expect(activity.nextCheck() == nil)
            #expect(activity.update(isPlaying: false, now: at(60)) == nil)  // already paused: once per quiet spell
            // Playing again: running, and the next quiet spell counts from when it stops.
            #expect(activity.update(isPlaying: true, now: at(61)) == nil)
            #expect(!activity.isPaused)
            #expect(activity.update(isPlaying: true, now: at(90)) == nil)
            #expect(activity.update(isPlaying: false, now: at(100)) == nil)
            #expect(activity.nextCheck() == at(100) + TapActivity.idleDelay)
            #expect(activity.update(isPlaying: false, now: at(100) + TapActivity.idleDelay) == .pause)
            // N2: a tap built while its app is quiet is already waiting for audio (its own TapAutoStart start), so
            // it counts as paused: no pause gets queued behind that start to fire on the first sound.
            var quiet = TapActivity(now: t0, isPlaying: false)
            #expect(quiet.isPaused)
            #expect(quiet.nextCheck() == nil)
            #expect(quiet.update(isPlaying: false, now: t0 + TapActivity.idleDelay) == nil)
            #expect(quiet.update(isPlaying: false, now: at(60)) == nil)
            // Once it has played, the usual quiet spell applies.
            #expect(quiet.update(isPlaying: true, now: at(61)) == nil)
            #expect(!quiet.isPaused)
            #expect(quiet.update(isPlaying: false, now: at(70)) == nil)
            #expect(quiet.update(isPlaying: false, now: at(70) + TapActivity.idleDelay) == .pause)
            #expect(TapActivity.idleDelay >= .seconds(2) && TapActivity.idleDelay <= .seconds(10))
        }

        /// N3: releasing a tap never waits for a start that may only return with the app's next sound. While the
        /// tap's queue sits in such a start, the teardown runs from outside it; when the start returns afterwards,
        /// the queue sees the tap is gone and stops there.
        @Test func tapReleaseNeverWaitsForABlockedStart() {
            var life = TapLifecycle()
            let a1 = life.invalidate(); #expect(a1 == .onQueue)              // not waiting: the tap's own queue tears down
            let a2 = life.beginWaitingStart(); #expect(!a2)                  // an invalidated tap never starts again
            let a3 = life.claimTeardown(); #expect(a3)
            let a4 = life.claimTeardown(); #expect(!a4)                      // exactly one teardown
            let a5 = life.invalidate(); #expect(a5 == .alreadyDone)

            var waiting = TapLifecycle()
            let b1 = waiting.beginWaitingStart(); #expect(b1)
            #expect(waiting.isWaitingForAudio)
            let b2 = waiting.invalidate(); #expect(b2 == .fromOutside)       // blocked start: tear down from outside now
            let b3 = waiting.claimTeardown(); #expect(b3)
            let b4 = waiting.endWaitingStart(); #expect(!b4)                 // the start returned later: stop, report nothing
            #expect(!waiting.isWaitingForAudio)

            var normal = TapLifecycle()
            let c1 = normal.beginWaitingStart(); #expect(c1)
            let c2 = normal.endWaitingStart(); #expect(c2)                   // returned with the tap alive: carry on
            let c3 = normal.invalidate(); #expect(c3 == .onQueue)

            // A creation failure tears down by itself; a later release has nothing left to do.
            var failed = TapLifecycle()
            let d1 = failed.claimTeardown(); #expect(d1)
            let d2 = failed.invalidate(); #expect(d2 == .alreadyDone)
        }

        /// R1: a replaced tap stays alive only until its successor starts, and never outlives its app's release.
        /// Scenario 1: Chrome's paused tap A (Headset, 50 %) is replaced by B (Speakers), whose first start waits;
        /// Chrome is reset to 100 % before B starts. Both A and B go: nothing is left to play Chrome at 50 %.
        @Test func releasingAnAppReleasesItsReplacedTaps() {
            var roster = TapRoster<String>()
            roster.install("A", for: "chrome")
            let a = roster.started("A", for: "chrome"); #expect(a.isEmpty)
            roster.install("B", for: "chrome")
            #expect(roster.current(for: "chrome") == "B")
            #expect(roster.retiring(for: "chrome") == ["A"])
            let released = roster.release("chrome")
            #expect(Set(released) == ["A", "B"])
            #expect(roster.isEmpty)
            // B never reports (released before it got going); a late report of either changes nothing.
            let lateB = roster.started("B", for: "chrome"); #expect(lateB.isEmpty)
            let lateA = roster.failed("A", for: "chrome"); #expect(lateA.isEmpty)
        }

        /// Scenario 2: released while B is still being built (no start yet): same rule, A (playing) goes with it.
        @Test func releasingDuringCreationReleasesThePredecessor() {
            var roster = TapRoster<String>()
            roster.install("A", for: "chrome")
            _ = roster.started("A", for: "chrome")
            roster.install("B", for: "chrome")                    // B is still being created
            #expect(Set(roster.release("chrome")) == ["A", "B"])
            #expect(roster.current(for: "chrome") == nil)
            #expect(roster.retiring(for: "chrome").isEmpty)
            // Other apps are untouched.
            roster.install("X", for: "discord")
            roster.install("C", for: "chrome")
            #expect(roster.release("chrome") == ["C"])
            #expect(roster.current(for: "discord") == "X")
        }

        /// Scenario 3: a chain A → B → C where C starts before B did. C's start releases every tap built before it, so A
        /// (playing) can't keep playing alongside C; B, which never started, already went when C replaced it. A start
        /// of B reported after C replaced it changes nothing. A B that did start before C was built is the one kept.
        @Test func aStartReleasesEveryOlderTap() {
            var roster = TapRoster<String>()
            roster.install("A", for: "chrome")
            _ = roster.started("A", for: "chrome")
            roster.install("B", for: "chrome")
            let replaced = roster.install("C", for: "chrome")
            #expect(replaced == ["B"])
            #expect(roster.retiring(for: "chrome") == ["A"])
            let lateB = roster.started("B", for: "chrome")
            #expect(lateB.isEmpty)
            let c = roster.started("C", for: "chrome")
            #expect(c == ["A"])
            #expect(roster.retiring(for: "chrome").isEmpty)
            #expect(roster.current(for: "chrome") == "C")

            var other = TapRoster<String>()
            other.install("A", for: "chrome")
            _ = other.started("A", for: "chrome")
            other.install("B", for: "chrome")
            let b = other.started("B", for: "chrome")
            #expect(b == ["A"])
            let none = other.install("C", for: "chrome")
            #expect(none.isEmpty)
            #expect(other.retiring(for: "chrome") == ["B"])
            let c2 = other.started("C", for: "chrome")
            #expect(c2 == ["B"])
            #expect(Set(other.all) == ["C"])
        }

        /// A failed current tap goes with every tap built before it (the app then plays as usual, and no successor is
        /// left to release them). `releaseAll` empties everything (feature off, quit).
        @Test func aFailureReleasesItAndOlderTaps() {
            var roster = TapRoster<String>()
            roster.install("A", for: "chrome")
            _ = roster.started("A", for: "chrome")
            roster.install("B", for: "chrome")
            #expect(Set(roster.failed("B", for: "chrome")) == ["A", "B"])
            #expect(roster.isEmpty)
            roster.install("C", for: "chrome")
            roster.install("X", for: "discord")
            #expect(Set(roster.releaseAll()) == ["C", "X"])
            #expect(roster.isEmpty)
            #expect(roster.currentByApp.isEmpty)
        }

        /// F3: a retiring tap that fails takes only itself. Chrome plays through A at 50 %; B replaced it, then C replaced
        /// B while C is still being built; B fails. A keeps Chrome at 50 % until C starts, instead of Chrome being heard
        /// unattenuated meanwhile. Nothing is stranded: C's start, C's failure or Chrome's release takes A.
        @Test func aFailedRetiringTapReleasesOnlyItself() {
            func chain() -> TapRoster<String> {
                var roster = TapRoster<String>()
                roster.install("A", for: "chrome")
                _ = roster.started("A", for: "chrome")
                roster.install("B", for: "chrome")
                roster.install("C", for: "chrome")
                return roster
            }
            var roster = chain()
            let b = roster.failed("B", for: "chrome")
            #expect(!b.contains("A"))
            #expect(Set(roster.all) == ["A", "C"])
            #expect(roster.current(for: "chrome") == "C")
            let c = roster.started("C", for: "chrome")
            #expect(c == ["A"])
            #expect(roster.all == ["C"])
            var failing = chain()
            _ = failing.failed("B", for: "chrome")
            let cFailed = failing.failed("C", for: "chrome")
            #expect(Set(cFailed) == ["A", "C"])
            #expect(failing.isEmpty)
            var reset = chain()
            _ = reset.failed("B", for: "chrome")
            let released = reset.release("chrome")
            #expect(Set(released) == ["A", "C"])
            #expect(reset.isEmpty)
        }

        /// F2: a quiet app with a remembered setting, rebuilt again and again while none of its taps starts (AirPods
        /// flapping between outputs, process-list churn). Each rebuild releases the replaced taps that never started:
        /// they aren't playing, so that is silent, and they can't pile up, each holding a process tap, an aggregate and
        /// a thread blocked in its start, to all start at the app's first sound at stale gains and devices. A tap that
        /// has started (playing, or paused and re-armed) stays until its successor starts, but only the newest one.
        @Test func rebuildsOfAQuietAppDoNotPileUp() {
            var slack = TapRoster<Int>()
            let first = slack.install(1, for: "slack")
            #expect(first.isEmpty)
            for serial in 2...20 {
                let released = slack.install(serial, for: "slack")
                #expect(released == [serial - 1])
            }
            #expect(slack.all == [20])
            #expect(slack.retiring(for: "slack").isEmpty)

            // Chrome played through A, then is rebuilt on and on while quiet: only A is kept, for when it plays again.
            var chrome = TapRoster<String>()
            chrome.install("A", for: "chrome")
            _ = chrome.started("A", for: "chrome")
            let b = chrome.install("B", for: "chrome")
            #expect(b.isEmpty)                                       // A may be playing: it waits for B's start
            let c = chrome.install("C", for: "chrome")
            #expect(c == ["B"])                                      // B never started
            let d = chrome.install("D", for: "chrome")
            #expect(d == ["C"])
            #expect(chrome.retiring(for: "chrome") == ["A"])
            // Late reports from the released ones change nothing.
            let lateB = chrome.started("B", for: "chrome")
            let lateC = chrome.failed("C", for: "chrome")
            #expect(lateB.isEmpty && lateC.isEmpty)
            #expect(Set(chrome.all) == ["A", "D"])
            // D starts: A goes. D is then the newest tap that started, and the one kept through the next rebuilds.
            let dStarted = chrome.started("D", for: "chrome")
            #expect(dStarted == ["A"])
            let e = chrome.install("E", for: "chrome")
            let f = chrome.install("F", for: "chrome")
            #expect(e.isEmpty && f == ["E"])
            #expect(chrome.retiring(for: "chrome") == ["D"])
            // The kept tap failing takes only itself; the app's release takes the rest.
            let dFailed = chrome.failed("D", for: "chrome")
            #expect(dFailed == ["D"])
            #expect(chrome.release("chrome") == ["F"])
            #expect(chrome.isEmpty)

            // Any mix of rebuilds, starts and failures: at most one replaced tap stays, and only one that started.
            var roster = TapRoster<Int>()
            var started: Set<Int> = []
            var seed: UInt64 = 7
            func next(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(bound))
            }
            var serial = 0
            for _ in 0..<500 {
                switch next(4) {
                case 0, 1:
                    serial += 1
                    _ = roster.install(serial, for: "app")
                case 2:
                    let tap = next(serial + 1)
                    if roster.all.contains(tap) { started.insert(tap) }
                    _ = roster.started(tap, for: "app")
                default:
                    _ = roster.failed(next(serial + 1), for: "app")
                }
                let retiring = roster.retiring(for: "app")
                #expect(retiring.count <= 1)
                #expect(retiring.allSatisfy(started.contains))
            }
        }

        /// G2: a rebuild in the gap between a tap's start returning (its app began to play) and that start being noted
        /// (`started`). The tap still counts as never started, but its app's processes are playing right now, so it may
        /// be the one playing the app: it is kept until its successor starts, not released while it plays. The newest
        /// tap that started stays too. Only the newest never-started tap is kept that way; a quiet app's never-started
        /// taps still go at once.
        @Test func aTapThatJustStartedIsKeptWhileItsAppPlays() {
            var roster = TapRoster<String>()
            roster.install("A", for: "chrome")
            _ = roster.started("A", for: "chrome")
            roster.install("B", for: "chrome")                          // B's start returns as Chrome plays; not noted yet
            var asked: [String] = []
            let c = roster.install("C", for: "chrome", isPlaying: { asked.append($0); return $0 == "B" })
            #expect(c.isEmpty)
            #expect(asked == ["B"])                                     // only the newest never-started tap is looked at
            #expect(roster.retiring(for: "chrome") == ["A", "B"])
            let cStarted = roster.started("C", for: "chrome")
            #expect(Set(cStarted) == ["A", "B"])
            #expect(roster.all == ["C"])
            // B's start is noted before C starts: B takes A with it, then C takes B.
            var noted = TapRoster<String>()
            noted.install("A", for: "chrome")
            _ = noted.started("A", for: "chrome")
            noted.install("B", for: "chrome")
            _ = noted.install("C", for: "chrome", isPlaying: { _ in true })
            #expect(noted.started("B", for: "chrome") == ["A"])
            #expect(noted.retiring(for: "chrome") == ["B"])
            #expect(noted.started("C", for: "chrome") == ["B"])
            // Several never-started taps while playing: only the newest is kept.
            var app = TapRoster<String>()
            app.install("B", for: "app")
            #expect(app.install("C", for: "app", isPlaying: { _ in true }).isEmpty)
            #expect(app.retiring(for: "app") == ["B"])
            #expect(app.install("D", for: "app", isPlaying: { _ in true }) == ["B"])
            #expect(app.retiring(for: "app") == ["C"])
            // Quiet again: never-started taps go at once.
            #expect(Set(app.install("E", for: "app", isPlaying: { _ in false })) == ["C", "D"])
            #expect(app.retiring(for: "app").isEmpty)
            // A started tap is kept without asking.
            var started = TapRoster<String>()
            started.install("A", for: "app")
            _ = started.started("A", for: "app")
            var looked = false
            #expect(started.install("B", for: "app", isPlaying: { _ in looked = true; return true }).isEmpty)
            #expect(!looked && started.retiring(for: "app") == ["A"])

            // Any mix of rebuilds (playing or quiet), starts and failures: at most two replaced taps stay, at most one
            // of them not noted as started, and that one only if the app was playing at the last rebuild.
            var mix = TapRoster<Int>()
            var seen: Set<Int> = []
            var seed: UInt64 = 11
            func next(_ bound: Int) -> Int {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Int((seed >> 33) % UInt64(bound))
            }
            var serial = 0
            var playingAtLastInstall = false
            for _ in 0..<500 {
                switch next(4) {
                case 0, 1:
                    serial += 1
                    let playing = next(2) == 0
                    playingAtLastInstall = playing
                    _ = mix.install(serial, for: "app", isPlaying: { _ in playing })
                case 2:
                    let tap = next(serial + 1)
                    if mix.all.contains(tap) { seen.insert(tap) }
                    _ = mix.started(tap, for: "app")
                default:
                    _ = mix.failed(next(serial + 1), for: "app")
                }
                let retiring = mix.retiring(for: "app")
                let unnoted = retiring.filter { !seen.contains($0) }
                #expect(retiring.count <= 2)
                #expect(unnoted.count <= (playingAtLastInstall ? 1 : 0))
            }
        }

        /// No output device at all: nothing to play on, so never a tap (it would only mute the app).
        @Test func noTapWithoutOutput() {
            #expect(!TapPlan(preference: AppAudioPreference(volume: 50), defaultOutputUID: nil).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(muted: true), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: ["Speakers"]).needsTap)
        }
    }
}
