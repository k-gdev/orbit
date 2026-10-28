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

        /// macOS switched the input while muted: the old mic is put back, the new one is muted.
        @Test func followsInputChange() {
            var state = MicMuteState()
            _ = state.mute(headset)
            let builtIn = MicDeviceReading(deviceUID: "BuiltIn", canSetMute: true, isMuted: false, canSetVolume: true, volume: 1)
            let r13 = state.retarget(to: builtIn); #expect(r13 == [.setMute(deviceUID: "Headset", muted: false), .setMute(deviceUID: "BuiltIn", muted: true)])
            #expect(state.deviceUID == "BuiltIn")
            // To a device Orbit can't mute: the old one is restored and the mute ends.
            let fixed = MicDeviceReading(deviceUID: "Fixed", canSetMute: false, isMuted: false, canSetVolume: false, volume: nil)
            let r14 = state.retarget(to: fixed); #expect(r14 == [.setMute(deviceUID: "BuiltIn", muted: false)])
            #expect(!state.isMuted)
            // Not muted: following the input does nothing.
            let r15 = state.retarget(to: headset); #expect(r15 == [])
            #expect(!state.isMuted)
            // To no device at all.
            _ = state.mute(headset)
            let r16 = state.retarget(to: nil); #expect(r16 == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(!state.isMuted)
            // Same device again (a spurious notification): nothing to do.
            _ = state.mute(headset)
            let r17 = state.retarget(to: headset); #expect(r17 == [])
            #expect(state.isMuted)
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
            var mutedNow = headset
            mutedNow.isMuted = true
            #expect(MicMuteState.recoveryActions(for: record, current: mutedNow) == [.setMute(deviceUID: "Headset", muted: false)])
            #expect(MicMuteState.recoveryActions(for: record, current: headset) == [])
            #expect(MicMuteState.recoveryActions(for: record, current: nil) == [])
            var other = mutedNow
            other.deviceUID = "Other"
            #expect(MicMuteState.recoveryActions(for: record, current: other) == [])
            #expect(MicMuteState.recoveryActions(for: MicMuteState(), current: mutedNow) == [])

            var volumeState = MicMuteState()
            let noMute = MicDeviceReading(deviceUID: "USB", canSetMute: false, isMuted: false, canSetVolume: true, volume: 0.62)
            _ = volumeState.mute(noMute)
            var atZero = noMute
            atZero.volume = 0
            #expect(MicMuteState.recoveryActions(for: volumeState, current: atZero) == [.setVolume(deviceUID: "USB", volume: 0.62)])
            #expect(MicMuteState.recoveryActions(for: volumeState, current: noMute) == [])
            // A user mute that was already there before Orbit is never undone.
            var userMuted = MicMuteState()
            _ = userMuted.mute(mutedNow)
            #expect(MicMuteState.recoveryActions(for: userMuted, current: mutedNow) == [])
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

        /// No output device at all: nothing to play on, so never a tap (it would only mute the app).
        @Test func noTapWithoutOutput() {
            #expect(!TapPlan(preference: AppAudioPreference(volume: 50), defaultOutputUID: nil).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(muted: true), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: ["Speakers"]).needsTap)
        }
    }
}
