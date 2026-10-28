import Foundation
import Testing
@testable import OrbitCore

/// The Orbit Suite shell model: features, permissions, persisted suite settings, hot key combos,
/// pill slider scales and Settings pages.
@Suite struct SuiteTests {
    @Test func featureOrderMatchesTabs() {
        #expect(FeatureID.allCases.map(\.title) == ["Sound", "System", "Displays", "Windows", "Clipboard", "Shelf", "Wallpaper", "Controls"])
        #expect(FeatureID.allCases.map(\.symbol) == ["speaker.wave.2", "cpu", "display", "macwindow.on.rectangle",
                                                     "doc.on.clipboard", "tray", "photo.on.rectangle", "switch.2"])
        #expect(FeatureID.allCases.allSatisfy { !$0.summary.isEmpty })
        #expect(Set(FeatureID.allCases.filter(\.isOnByDefault)) == [.system, .displays, .shelf, .wallpaper, .controls])
    }

    @Test func permissionsTable() {
        #expect(FeatureID.system.permissions.isEmpty)
        #expect(FeatureID.displays.permissions.isEmpty)
        #expect(FeatureID.shelf.permissions.isEmpty)
        #expect(FeatureID.wallpaper.permissions.isEmpty)
        #expect(FeatureID.sound.permissions == [PermissionUse(permission: .systemAudioRecording,
                                                              purpose: "Per-app volume, boost and output", requestOnEnable: true)])
        #expect(FeatureID.windows.permissions.map(\.permission) == [.accessibility, .screenRecording])
        #expect(FeatureID.windows.permissions.allSatisfy { $0.requestOnEnable })
        #expect(FeatureID.clipboard.permissions.map(\.permission) == [.accessibility])
        #expect(FeatureID.clipboard.permissions.first?.requestOnEnable == false)
        #expect(FeatureID.controls.permissions == [PermissionUse(permission: .screenRecording,
                                                                 purpose: "Grab Text captures the area you select", requestOnEnable: false)])
        // A feature that is on by default must never prompt the moment it starts.
        #expect(FeatureID.allCases.filter(\.isOnByDefault).allSatisfy { feature in !feature.permissions.contains { $0.requestOnEnable } })
    }

    @Test func permissionSettingsURLs() {
        #expect(SuitePermission.systemAudioRecording.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        #expect(SuitePermission.accessibility.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(SuitePermission.screenRecording.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        #expect(SuitePermission.allCases.allSatisfy { !$0.title.isEmpty })
    }

    /// Process taps (System Audio Recording) arrived in macOS 14.2; the other permissions exist on 14.0.
    @Test func permissionSystemRequirements() {
        let v14_0 = OperatingSystemVersion(majorVersion: 14, minorVersion: 0, patchVersion: 0)
        let v14_1 = OperatingSystemVersion(majorVersion: 14, minorVersion: 1, patchVersion: 9)
        let v14_2 = OperatingSystemVersion(majorVersion: 14, minorVersion: 2, patchVersion: 0)
        let v26 = OperatingSystemVersion(majorVersion: 26, minorVersion: 5, patchVersion: 0)
        #expect(!SuitePermission.systemAudioRecording.isAvailable(on: v14_0))
        #expect(!SuitePermission.systemAudioRecording.isAvailable(on: v14_1))
        #expect(SuitePermission.systemAudioRecording.isAvailable(on: v14_2))
        #expect(SuitePermission.systemAudioRecording.isAvailable(on: v26))
        #expect(SuitePermission.accessibility.isAvailable(on: v14_0))
        #expect(SuitePermission.screenRecording.isAvailable(on: v14_0))
        #expect(SuitePermission.systemAudioRecording.minimumSystemVersion?.minorVersion == 2)
        #expect(SuitePermission.accessibility.minimumSystemVersion == nil)
    }

    @Test func keyComboDisplay() throws {
        #expect(KeyCombo.micMuteDefault.display == "⌃⌥M")
        #expect(KeyCombo.clipboardDefault.display == "⇧⌘V")
        #expect(KeyCombo.grabTextDefault.display == "⇧⌘2")
        #expect(KeyCombo.grabTextDefault == KeyCombo(keyCode: 19, modifiers: [.shift, .command]))
        #expect(KeyCombo.micMuteDefault == KeyCombo(keyCode: 46, modifiers: [.control, .option]))
        #expect(KeyCombo.clipboardDefault == KeyCombo(keyCode: 9, modifiers: [.shift, .command]))
        // Apple order regardless of how the set was built.
        #expect(KeyCombo(keyCode: 0, modifiers: [.command, .shift, .option, .control]).display == "⌃⌥⇧⌘A")
        let data = try JSONEncoder().encode(KeyCombo.micMuteDefault)
        #expect(try JSONDecoder().decode(KeyCombo.self, from: data) == KeyCombo.micMuteDefault)
    }

    @Test func keyNames() {
        #expect(KeyCombo.keyName(for: 0) == "A")
        #expect(KeyCombo.keyName(for: 29) == "0")
        #expect(KeyCombo.keyName(for: 18) == "1")
        #expect(KeyCombo.keyName(for: 122) == "F1")
        #expect(KeyCombo.keyName(for: 111) == "F12")
        #expect(KeyCombo.keyName(for: 49) == "Space")
        #expect(KeyCombo.keyName(for: 36) == "↩")
        #expect([123, 124, 125, 126].map { KeyCombo.keyName(for: $0) } == ["←", "→", "↓", "↑"])
        #expect(KeyCombo.keyName(for: 0xFF) == nil)
        // Every ANSI letter has a name, and they are 26 distinct ones.
        let letters = (0...127).compactMap { KeyCombo.keyName(for: UInt16($0)) }.filter { $0.count == 1 && $0.first!.isLetter }
        #expect(Set(letters).count == 26)
        // A key without a name still displays something.
        #expect(KeyCombo(keyCode: 0xFF, modifiers: [.command]).display == "⌘Key 255")
    }

    @Test func hotKeyUsability() {
        #expect(KeyCombo.micMuteDefault.isUsableAsHotKey)
        #expect(KeyCombo(keyCode: 122, modifiers: []).isUsableAsHotKey)       // F1 alone is fine
        #expect(!KeyCombo(keyCode: 0, modifiers: []).isUsableAsHotKey)        // a bare letter is not
        #expect(!KeyCombo(keyCode: 0, modifiers: [.shift]).isUsableAsHotKey)  // nor shift + letter
        #expect(!KeyCombo(keyCode: 0xFF, modifiers: [.command]).isUsableAsHotKey)
    }

    @Test func pillScale() {
        let boosted = PillScale(maximum: 150)
        #expect(abs(boosted.boostStartFraction - 2.0 / 3.0) < 0.0001)
        #expect(boosted.hasBoost)
        #expect(boosted.fraction(for: 75) == 0.5)
        #expect(boosted.fraction(for: 300) == 1)
        #expect(boosted.fraction(for: -5) == 0)
        #expect(boosted.value(forFraction: 1.2) == 150)
        #expect(boosted.value(forFraction: -0.1) == 0)
        #expect(boosted.value(forFraction: 0.5) == 75)
        #expect(boosted.value(forFraction: 0.501, step: 5) == 75)
        #expect(boosted.isBoosted(120) && !boosted.isBoosted(100))
        #expect(boosted.clamped(151) == 150 && boosted.clamped(-1) == 0)
        let plain = PillScale(maximum: 100)
        #expect(plain.hasBoost == false)
        #expect(plain.boostStartFraction == 1)
        #expect(!plain.isBoosted(100))
        #expect(PillScale(maximum: 0).fraction(for: 10) == 0)
    }

    /// The pill's fill is never narrower than a circle (it holds the leading icon), and a drag puts the
    /// end of the fill under the pointer.
    @Test func pillTrackGeometry() {
        let t = PillTrack(width: 330, height: 30)
        #expect(t.fillWidth(forFraction: 0) == 30)
        #expect(t.fillWidth(forFraction: 1) == 330)
        #expect(t.fillWidth(forFraction: 0.5) == 180)
        #expect(t.fillWidth(forFraction: 2) == 330)
        #expect(t.fraction(atX: 15) == 0)
        #expect(t.fraction(atX: 315) == 1)
        #expect(t.fraction(atX: 165) == 0.5)
        #expect(t.fraction(atX: -50) == 0 && t.fraction(atX: 999) == 1)
        // Too narrow to have a travel: everything maps to the start.
        #expect(PillTrack(width: 20, height: 30).fraction(atX: 10) == 0)
        #expect(PillTrack(width: 20, height: 30).fillWidth(forFraction: 1) == 20)
        // Round trip through the scale: a drag to the middle of a 0...150 pill is 75.
        #expect(PillScale(maximum: 150).value(forFraction: t.fraction(atX: 165)) == 75)
    }

    @Test func pillWheelStep() {
        #expect(PillScale(maximum: 150).wheelStep(step: 1) == 3)
        #expect(PillScale(maximum: 100).wheelStep(step: 1) == 2)
        #expect(PillScale(maximum: 100).wheelStep(step: 5) == 5)
        #expect(PillScale(maximum: 1).wheelStep(step: 0.01) == 0.02)
        #expect(PillScale(maximum: 150).nudged(149, by: 1, step: 3) == 150)
        #expect(PillScale(maximum: 150).nudged(2, by: -1, step: 3) == 0)
        #expect(PillScale(maximum: 150).nudged(90, by: 2, step: 3) == 96)
        // A wheel notch moves by the wheel step but stays on the slider's own step grid.
        #expect(PillScale(maximum: 150).wheelNudged(91, notches: 1, step: 1) == 94)
        #expect(PillScale(maximum: 150).wheelNudged(91, notches: -2, step: 1) == 85)
        #expect(PillScale(maximum: 100).wheelNudged(99, notches: 1, step: 1) == 100)
    }

    /// A pill can show a range further than it lets the user set (a monitor's own boost, which DDC can't write).
    @Test func pillScaleWithASettableLimit() {
        let scale = PillScale(maximum: 150, boostStart: 100, limit: 100)
        #expect(scale.settableMaximum == 100)
        #expect(PillScale(maximum: 150).settableMaximum == 150)
        #expect(PillScale(maximum: 150) == PillScale(maximum: 150, limit: nil))
        // A limit past the range is the range.
        #expect(PillScale(maximum: 150, limit: 400).settableMaximum == 150)
        // What is shown is unchanged: the whole 0...150 track, striped past 100, a 150 reading shown in full.
        #expect(scale.hasBoost && scale.isBoosted(150))
        #expect(scale.fraction(for: 150) == 1)
        #expect(scale.clamped(150) == 150)
        // Dragging into the striped zone stops at the limit.
        #expect(scale.value(forFraction: 0.5) == 75)
        #expect(scale.value(forFraction: 100.0 / 150.0) == 100)
        #expect(scale.value(forFraction: 0.9) == 100)
        #expect(scale.value(forFraction: 1) == 100)
        // So do wheel notches, keys and accessibility increments.
        #expect(scale.nudged(98, by: 5) == 100)
        #expect(scale.wheelNudged(99, notches: 3, step: 1) == 100)
        #expect(scale.moved(98, by: 5) == 100)
        // Nudging up from a boost the monitor set itself changes nothing; nudging down comes to the limit.
        #expect(scale.nudged(150, by: 1) == 150)
        #expect(scale.wheelNudged(150, notches: 1, step: 1) == 150)
        #expect(scale.moved(150, by: 4) == 150)
        #expect(scale.nudged(150, by: -1) == 100)
        #expect(scale.wheelNudged(150, notches: -1, step: 1) == 100)
        #expect(scale.moved(150, by: -4) == 100)
        // Below the limit everything moves as before.
        #expect(scale.nudged(50, by: -1) == 49)
        #expect(scale.moved(50, by: 2.5) == 52.5)
        #expect(scale.moved(1, by: -5) == 0)
        // Without a limit nothing changes.
        #expect(PillScale(maximum: 150).nudged(150, by: 1) == 150)
        #expect(PillScale(maximum: 150).moved(149, by: 5) == 150)
    }

    @Test func settingsPageArguments() {
        #expect(SettingsPage(argument: "sound") == .feature(.sound))
        #expect(SettingsPage(argument: "features") == .features)
        #expect(SettingsPage(argument: "general") == .general)
        #expect(SettingsPage(argument: "wheel") == .wheel)
        #expect(SettingsPage(argument: "about") == .about)
        #expect(SettingsPage(argument: "nope") == nil)
        #expect(SettingsPage.railOrder.count == 12)
        #expect(SettingsPage(argument: "controls") == .feature(.controls))
        #expect(SettingsPage.railOrder.first == .general && SettingsPage.railOrder.last == .about)
        #expect(SettingsPage.railOrder.map(\.argument).compactMap(SettingsPage.init(argument:)) == SettingsPage.railOrder)
        #expect(SettingsPage.feature(.clipboard).title == "Clipboard")
        #expect(SettingsPage.feature(.clipboard).symbol == FeatureID.clipboard.symbol)
    }
}

extension SuiteTests {
    /// Which features are on, and the panel's last tab, persist in `UserDefaults`.
    @Suite struct SuiteSettingsTests {
        @Test func enabledSetRoundTrips() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            let s = SuiteSettings(defaults: d)
            #expect(s.enabledFeatures == [.system, .displays, .shelf, .wallpaper, .controls])
            #expect(s.enabledInOrder == [.system, .displays, .shelf, .wallpaper, .controls])
            s.enabledFeatures.insert(.sound)
            let r = SuiteSettings(defaults: d)
            #expect(r.enabledFeatures.contains(.sound))
            #expect(r.isEnabled(.sound))
            #expect(!r.isEnabled(.clipboard))
            #expect(r.enabledInOrder.first == .sound)
            r.setEnabled(.system, false)
            r.setEnabled(.clipboard, true)
            #expect(SuiteSettings(defaults: d).enabledInOrder == [.sound, .displays, .clipboard, .shelf, .wallpaper, .controls])
            // Everything off is remembered as off, not reset to the defaults.
            r.enabledFeatures = []
            #expect(SuiteSettings(defaults: d).enabledFeatures.isEmpty)
        }

        @Test func unknownFeatureIDsAreIgnored() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            d.set(["sound", "teleporter"], forKey: "suite.enabledFeatures")
            #expect(SuiteSettings(defaults: d).enabledFeatures == [.sound])
        }

        @Test func lastTabPersists() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            #expect(SuiteSettings(defaults: d).lastTab == nil)
            SuiteSettings(defaults: d).lastTab = .displays
            #expect(SuiteSettings(defaults: d).lastTab == .displays)
            SuiteSettings(defaults: d).lastTab = nil
            #expect(SuiteSettings(defaults: d).lastTab == nil)
            d.set("teleporter", forKey: "suite.lastTab")
            #expect(SuiteSettings(defaults: d).lastTab == nil)
        }

        /// The mic mute shortcut is shared by Sound and Controls, so it has its own tiny store.
        @Test func micMuteShortcutRoundTrips() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            #expect(MicMuteSettings(defaults: d).muteShortcut == .micMuteDefault)
            let combo = KeyCombo(keyCode: 46, modifiers: [.command, .option])
            MicMuteSettings(defaults: d).muteShortcut = combo
            #expect(MicMuteSettings(defaults: d).muteShortcut == combo)
            #expect(d.data(forKey: "micMute.shortcut") != nil)
            d.set(Data("junk".utf8), forKey: "micMute.shortcut")
            #expect(MicMuteSettings(defaults: d).muteShortcut == .micMuteDefault)
        }
    }
}
