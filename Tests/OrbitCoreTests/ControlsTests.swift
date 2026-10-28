import Foundation
import Testing
@testable import OrbitCore

/// Controls (spec §8): Keep Awake sessions, download detection, quick toggle restore records, the eject
/// filter, Grab Text results and the persisted settings. Nothing here touches the real machine: no power
/// assertion, no preference write, no volume, no screen capture.
@Suite struct ControlsTests {}

// MARK: - Keep Awake

extension ControlsTests {
    @Suite struct KeepAwakeTests {
        private let start = Date(timeIntervalSince1970: 1_800_000_000)
        private let utc = TimeZone(identifier: "UTC")!
        private let gb = Locale(identifier: "en_GB")

        private func session(_ mode: KeepAwakeMode, display: Bool = false, appName: String? = nil) -> KeepAwakeSession {
            KeepAwakeSession(startDate: start, mode: mode, keepDisplayAwake: display, appName: appName)
        }

        @Test func expiresAtDeadline() {
            let s = session(.duration(3600))
            #expect(s.deadline == start.addingTimeInterval(3600))
            #expect(!s.isExpired(now: start, appRunning: true, downloadsActive: true))
            #expect(!s.isExpired(now: start.addingTimeInterval(3599), appRunning: true, downloadsActive: true))
            #expect(s.isExpired(now: start.addingTimeInterval(3600), appRunning: true, downloadsActive: true))
            #expect(s.isExpired(now: start.addingTimeInterval(9000), appRunning: true, downloadsActive: true))
            #expect(s.remaining(now: start.addingTimeInterval(600)) == 3000)
            // Never negative, even long after the deadline (a Mac that slept through it).
            #expect(s.remaining(now: start.addingTimeInterval(99_999)) == 0)

            let until = session(.until(start.addingTimeInterval(1800)))
            #expect(!until.isExpired(now: start.addingTimeInterval(1799), appRunning: true, downloadsActive: true))
            #expect(until.isExpired(now: start.addingTimeInterval(1800), appRunning: true, downloadsActive: true))
            #expect(until.remaining(now: start) == 1800)
        }

        @Test func indefiniteNeverExpires() {
            let s = session(.indefinitely)
            #expect(s.deadline == nil)
            #expect(s.remaining(now: start) == nil)
            #expect(!s.isExpired(now: start.addingTimeInterval(86_400 * 365), appRunning: false, downloadsActive: false))
            #expect(s.label(now: start) == "Indefinitely")
        }

        @Test func whileAppRunningExpiresWhenAppQuits() {
            let s = session(.whileAppRunning(bundleID: "com.apple.dt.Xcode"), appName: "Xcode")
            #expect(s.remaining(now: start) == nil)
            #expect(!s.isExpired(now: start.addingTimeInterval(86_400), appRunning: true, downloadsActive: false))
            #expect(s.isExpired(now: start, appRunning: false, downloadsActive: true))
            #expect(s.label(now: start) == "While Xcode runs")
            // Without a resolved name, the bundle id's last part stands in.
            #expect(session(.whileAppRunning(bundleID: "com.apple.dt.Xcode")).label(now: start) == "While Xcode runs")
            #expect(KeepAwakeMode.fallbackAppName(for: "org.mozilla.firefox") == "Firefox")
            #expect(KeepAwakeMode.fallbackAppName(for: "") == "the app")
        }

        @Test func whileDownloadingFollowsDownloads() {
            let s = session(.whileDownloading)
            #expect(!s.isExpired(now: start.addingTimeInterval(86_400), appRunning: false, downloadsActive: true))
            #expect(s.isExpired(now: start, appRunning: true, downloadsActive: false))
            #expect(s.label(now: start) == "While downloading")
        }

        @Test func untilTimeLabel() {
            // 2027-01-15 20:00 UTC; until 23:30 the same day, then 07:00 the next morning.
            let now = Date(timeIntervalSince1970: 1_800_043_200)
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = utc
            let sameDay = cal.date(bySettingHour: 23, minute: 30, second: 0, of: now)!
            let s = KeepAwakeSession(startDate: now, mode: .until(sameDay), keepDisplayAwake: false)
            #expect(s.label(now: now, timeZone: utc, locale: gb) == "Until 23:30")
            let nextMorning = cal.date(byAdding: .day, value: 1, to: cal.date(bySettingHour: 7, minute: 0, second: 0, of: now)!)!
            let t = KeepAwakeSession(startDate: now, mode: .until(nextMorning), keepDisplayAwake: false)
            let label = t.label(now: now, timeZone: utc, locale: gb)
            #expect(label.hasPrefix("Until "))
            #expect(label.hasSuffix("07:00"))
            #expect(label != "Until 07:00")   // another day says which day
        }

        @Test func remainingLabels() {
            #expect(KeepAwakeFormat.remaining(4320) == "1 h 12 m left")
            #expect(KeepAwakeFormat.remaining(7200) == "2 h left")
            #expect(KeepAwakeFormat.remaining(3599) == "1 h left")      // rounds up to whole minutes
            #expect(KeepAwakeFormat.remaining(900) == "15 m left")
            #expect(KeepAwakeFormat.remaining(30) == "1 m left")
            #expect(KeepAwakeFormat.remaining(0) == "1 m left")
            let s = session(.duration(3600))
            #expect(s.label(now: start.addingTimeInterval(60)) == "59 m left")
        }

        @Test func durationTitles() {
            #expect(KeepAwakeMode.presetDurations == [900, 3600, 7200, 18_000])
            #expect(KeepAwakeFormat.duration(900) == "15 minutes")
            #expect(KeepAwakeFormat.duration(60) == "1 minute")
            #expect(KeepAwakeFormat.duration(3600) == "1 hour")
            #expect(KeepAwakeFormat.duration(7200) == "2 hours")
            #expect(KeepAwakeFormat.duration(18_000) == "5 hours")
            #expect(KeepAwakeFormat.duration(5400) == "1 hour 30 minutes")
            #expect(KeepAwakeFormat.duration(45 * 60) == "45 minutes")
        }

        @Test func modeRoundTripsThroughJSON() throws {
            let modes: [KeepAwakeMode] = [.indefinitely, .duration(900), .until(start), .whileAppRunning(bundleID: "com.apple.Safari"),
                                          .whileDownloading]
            for mode in modes {
                let data = try JSONEncoder().encode(mode)
                #expect(try JSONDecoder().decode(KeepAwakeMode.self, from: data) == mode)
            }
            let s = session(.duration(900), display: true, appName: nil)
            #expect(try JSONDecoder().decode(KeepAwakeSession.self, from: JSONEncoder().encode(s)) == s)
        }

        /// The Keep Awake switch restarts the last mode when it still makes sense, otherwise indefinitely.
        @Test func resumeMode() {
            #expect(KeepAwakeMode.resumable(nil, now: start) == .indefinitely)
            #expect(KeepAwakeMode.resumable(.indefinitely, now: start) == .indefinitely)
            #expect(KeepAwakeMode.resumable(.duration(3600), now: start) == .duration(3600))
            #expect(KeepAwakeMode.resumable(.duration(0), now: start) == .indefinitely)
            #expect(KeepAwakeMode.resumable(.until(start.addingTimeInterval(3600)), now: start) == .until(start.addingTimeInterval(3600)))
            #expect(KeepAwakeMode.resumable(.until(start.addingTimeInterval(-60)), now: start) == .indefinitely)
            #expect(KeepAwakeMode.resumable(.whileAppRunning(bundleID: "com.apple.Safari"), now: start) == .indefinitely)
            #expect(KeepAwakeMode.resumable(.whileDownloading, now: start) == .indefinitely)
        }

        @Test func modeTitles() {
            #expect(KeepAwakeMode.indefinitely.title() == "Indefinitely")
            #expect(KeepAwakeMode.duration(3600).title() == "1 hour")
            #expect(KeepAwakeMode.whileDownloading.title() == "While downloading")
            #expect(KeepAwakeMode.whileAppRunning(bundleID: "com.apple.dt.Xcode").title(appName: "Xcode") == "While Xcode runs")
        }
    }
}
