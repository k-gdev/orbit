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
    /// audio when "Show all apps" is on. Pinned first, then by name, so rows don't jump around.
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
        #expect(pinned.map(\.name) == ["RingCentral", "Spotify", "Google Chrome", "Music", "Slack"])

        let all = AudioAppList.visible(candidates, pinned: ["com.spotify.client"], customised: [], showAll: true, excluding: ["com.kevo.orbit"])
        #expect(all.map(\.name) == ["Spotify", "Discord", "Google Chrome", "Music", "RingCentral", "Slack"])

        // Two entries for one app (main process and a helper resolved separately) merge.
        let merged = AudioAppList.visible([app("a", "A"), app("a", "A", playing: true)], pinned: [], customised: [], showAll: false)
        #expect(merged.count == 1)
        #expect(merged.first?.isPlaying == true)
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

        /// No output device at all: nothing to play on, so never a tap (it would only mute the app).
        @Test func noTapWithoutOutput() {
            #expect(!TapPlan(preference: AppAudioPreference(volume: 50), defaultOutputUID: nil).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(muted: true), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(!TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: []).needsTap)
            #expect(TapPlan(preference: AppAudioPreference(outputUID: "Speakers"), defaultOutputUID: nil, availableOutputUIDs: ["Speakers"]).needsTap)
        }
    }
}
