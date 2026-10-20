import Foundation
import Testing
@testable import OrbitCore

@Suite struct FullDiskAccessTests {
    @Test func notGrantedWhenNoProbePathIsReadable() {
        #expect(!FullDiskAccess.isGranted(probe: { _ in false }))
    }

    @Test func grantedWhenEveryProbePathIsReadable() {
        #expect(FullDiskAccess.isGranted(probe: { _ in true }))
    }

    @Test func eitherPathSuffices() {
        for readable in FullDiskAccess.probePaths {
            #expect(FullDiskAccess.isGranted(probe: { $0 == readable }), "\(readable) alone should count as granted")
        }
    }

    @Test func probesTheTCCDatabaseAndSafariBookmarks() {
        #expect(FullDiskAccess.probePaths.contains("/Library/Application Support/com.apple.TCC/TCC.db"))
        let home = NSHomeDirectory()
        #expect(FullDiskAccess.probePaths.contains(home + "/Library/Safari/Bookmarks.plist"))
    }

    @Test func settingsURLOpensTheFullDiskAccessPane() {
        #expect(FullDiskAccess.settingsURL.absoluteString
                == "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }
}

@Suite struct WelcomeSettingTests {
    @Test func defaultsToNotSeen() {
        let (d, clean) = Fixtures.defaults(); defer { clean() }
        #expect(SettingsStore(defaults: d).hasSeenWelcome == false)
    }

    @Test func roundTrips() {
        let (d, clean) = Fixtures.defaults(); defer { clean() }
        let s = SettingsStore(defaults: d)
        s.hasSeenWelcome = true
        #expect(SettingsStore(defaults: d).hasSeenWelcome == true)
        s.hasSeenWelcome = false
        #expect(SettingsStore(defaults: d).hasSeenWelcome == false)
    }
}
