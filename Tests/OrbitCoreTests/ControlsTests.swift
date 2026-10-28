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

// MARK: - Keep Awake engine (fake asserter: no real power assertion is ever taken)

/// Records what the engine holds instead of calling IOKit.
final class FakeAsserter: PowerAsserting {
    private(set) var held: Set<PowerAssertionKind> = []
    private(set) var acquired: [PowerAssertionKind] = []
    private(set) var released: [PowerAssertionKind] = []
    var refuse = false

    func acquire(_ kind: PowerAssertionKind, reason: String) -> Bool {
        #expect(reason == "Orbit Keep Awake")
        guard !refuse else { return false }
        #expect(!held.contains(kind), "acquired \(kind) twice without releasing")
        held.insert(kind)
        acquired.append(kind)
        return true
    }

    func release(_ kind: PowerAssertionKind) {
        #expect(held.contains(kind), "released \(kind) that wasn't held")
        held.remove(kind)
        released.append(kind)
    }
}

extension ControlsTests.KeepAwakeTests {
    @Test func engineReleasesAtDeadline() {
        let fake = FakeAsserter()
        let engine = KeepAwakeEngine(asserter: fake)
        #expect(engine.start(.duration(900), keepDisplayAwake: true, now: start))
        #expect(fake.held == [.preventSystemSleep, .preventDisplaySleep])
        #expect(engine.isActive)
        #expect(!engine.evaluate(now: start.addingTimeInterval(899)))
        #expect(fake.held.count == 2)
        #expect(engine.evaluate(now: start.addingTimeInterval(900)))
        #expect(fake.held.isEmpty)
        #expect(!engine.isActive)
        #expect(engine.session == nil)
        // Nothing left to expire.
        #expect(!engine.evaluate(now: start.addingTimeInterval(1000)))
    }

    @Test func engineReleasesOnStopAndDeinit() {
        let fake = FakeAsserter()
        let engine = KeepAwakeEngine(asserter: fake)
        engine.start(.indefinitely, keepDisplayAwake: false, now: start)
        #expect(fake.held == [.preventSystemSleep])
        engine.stop()
        #expect(fake.held.isEmpty)
        engine.stop()   // idempotent
        #expect(fake.released == [.preventSystemSleep])

        let other = FakeAsserter()
        do {
            let scoped = KeepAwakeEngine(asserter: other)
            scoped.start(.indefinitely, keepDisplayAwake: true, now: start)
            #expect(other.held.count == 2)
        }
        #expect(other.held.isEmpty)   // released when the engine goes away
    }

    @Test func engineFollowsDisplayOption() {
        let fake = FakeAsserter()
        let engine = KeepAwakeEngine(asserter: fake)
        engine.start(.indefinitely, keepDisplayAwake: false, now: start)
        engine.setKeepDisplayAwake(true)
        #expect(fake.held == [.preventSystemSleep, .preventDisplaySleep])
        #expect(engine.session?.keepDisplayAwake == true)
        engine.setKeepDisplayAwake(false)
        #expect(fake.held == [.preventSystemSleep])
        // Restarting with another mode keeps one system assertion (no second one, no gap).
        engine.start(.duration(3600), keepDisplayAwake: true, now: start)
        #expect(fake.acquired.filter { $0 == .preventSystemSleep }.count == 1)
        #expect(engine.session?.mode == .duration(3600))
        // While off, the display option holds nothing.
        engine.stop()
        engine.setKeepDisplayAwake(true)
        #expect(fake.held.isEmpty)
    }

    @Test func engineEndsWithAppOrDownloads() {
        let fake = FakeAsserter()
        let engine = KeepAwakeEngine(asserter: fake)
        engine.start(.whileAppRunning(bundleID: "com.apple.dt.Xcode"), keepDisplayAwake: false, now: start, appName: "Xcode")
        #expect(engine.session?.appName == "Xcode")
        #expect(!engine.evaluate(now: start, appRunning: true))
        #expect(engine.evaluate(now: start, appRunning: false))
        #expect(fake.held.isEmpty)
        engine.start(.whileDownloading, keepDisplayAwake: false, now: start)
        #expect(!engine.evaluate(now: start, downloadsActive: true))
        #expect(engine.evaluate(now: start, downloadsActive: false))
        #expect(fake.held.isEmpty)
    }

    @Test func engineRefusedByMacOS() {
        let fake = FakeAsserter()
        fake.refuse = true
        let engine = KeepAwakeEngine(asserter: fake)
        #expect(!engine.start(.indefinitely, keepDisplayAwake: true, now: start))
        #expect(!engine.isActive)
        #expect(fake.held.isEmpty)
    }
}
