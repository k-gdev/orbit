import CoreText
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
    /// Kinds macOS refuses (for a refused display assertion alone).
    var refuseKinds: Set<PowerAssertionKind> = []

    func acquire(_ kind: PowerAssertionKind, reason: String) -> Bool {
        #expect(reason == "Orbit Keep Awake")
        guard !refuse, !refuseKinds.contains(kind) else { return false }
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

// MARK: - Downloads

extension ControlsTests {
    @Suite struct DownloadActivityTests {
        @Test func downloadSuffixes() {
            #expect(DownloadActivity.partialSuffixes == [".download", ".crdownload", ".part", ".partial", ".opdownload"])
            #expect(DownloadActivity.isActive(fileNames: ["movie.mp4.download"]))            // Safari (a bundle)
            #expect(DownloadActivity.isActive(fileNames: ["Unconfirmed 812.crdownload"]))    // Chrome, Edge, Arc
            #expect(DownloadActivity.isActive(fileNames: ["setup.dmg.part"]))                 // Firefox
            #expect(DownloadActivity.isActive(fileNames: ["a.zip.partial"]))
            #expect(DownloadActivity.isActive(fileNames: ["b.iso.opdownload"]))               // Opera
            #expect(DownloadActivity.isActive(fileNames: ["Report.pdf", "IMG.HEIC", "big.ZIP.CRDOWNLOAD"]))  // any case
            #expect(!DownloadActivity.isActive(fileNames: []))
            #expect(!DownloadActivity.isActive(fileNames: ["Report.pdf", "notes.txt", "partial.zip", "download.png"]))
            // A bare suffix (a hidden file named like one) is not a download.
            #expect(!DownloadActivity.isActive(fileNames: [".part", ".download"]))
            #expect(DownloadActivity.pollInterval == 10)
        }

        /// A browser briefly has no partial file between two downloads; the watch rides over that gap.
        @Test func watchBridgesShortGaps() {
            let t0 = Date(timeIntervalSince1970: 0)
            var watch = DownloadWatch(grace: 20)
            var results: [Bool] = []
            results.append(watch.update(active: false, now: t0))      // never seen one: not downloading
            results.append(watch.update(active: true, now: t0))
            results.append(watch.update(active: false, now: t0.addingTimeInterval(10)))
            results.append(watch.update(active: false, now: t0.addingTimeInterval(19)))
            results.append(watch.update(active: false, now: t0.addingTimeInterval(20)))
            results.append(watch.update(active: true, now: t0.addingTimeInterval(30)))
            #expect(results == [false, true, true, true, false, true])
            #expect(DownloadWatch().grace == 20)
        }
    }
}

// MARK: - Quick Toggles

extension ControlsTests {
    @Suite struct QuickToggleTests {
        @Test func togglesInOrder() {
            #expect(QuickToggleID.allCases == [.darkMode, .hideDesktopIcons, .showHiddenFiles, .nightShift, .doNotDisturb, .ejectDrives, .micMute])
            #expect(QuickToggleID.allCases.allSatisfy { !$0.title.isEmpty && !$0.symbol.isEmpty })
            #expect(QuickToggleID.allCases.filter(\.isAction) == [.doNotDisturb, .ejectDrives])
            #expect(QuickToggleID.allCases.filter(\.restartsFinder) == [.hideDesktopIcons, .showHiddenFiles])
            // Raw values persist (visible toggles, restore records).
            #expect(QuickToggleID(rawValue: "nightShift") == .nightShift)
        }

        @Test func preferenceParsing() {
            #expect(PreferenceValue.parse(nil) == .absent)
            #expect(PreferenceValue.parse(true) == .bool(true))
            #expect(PreferenceValue.parse(false) == .bool(false))
            #expect(PreferenceValue.parse(NSNumber(value: 1)) == .bool(true))
            #expect(PreferenceValue.parse(NSNumber(value: 0)) == .bool(false))
            #expect(PreferenceValue.parse(0) == .bool(false))
            // `defaults write com.apple.finder AppleShowAllFiles YES` stores a string.
            #expect(PreferenceValue.parse("YES") == .bool(true))
            #expect(PreferenceValue.parse("true") == .bool(true))
            #expect(PreferenceValue.parse("1") == .bool(true))
            #expect(PreferenceValue.parse("NO") == .bool(false))
            #expect(PreferenceValue.parse("off") == .bool(false))
            #expect(PreferenceValue.parse(Data()) == .absent)    // something unexpected reads as unset
        }

        @Test func onMeaning() {
            // Hiding desktop icons means CreateDesktop = false; unset means icons show.
            #expect(QuickToggleID.hideDesktopIcons.isOn(.bool(false)))
            #expect(!QuickToggleID.hideDesktopIcons.isOn(.absent))
            #expect(!QuickToggleID.hideDesktopIcons.isOn(.bool(true)))
            #expect(QuickToggleID.showHiddenFiles.isOn(.bool(true)))
            #expect(!QuickToggleID.showHiddenFiles.isOn(.absent))
            #expect(QuickToggleID.darkMode.isOn(.bool(true)))
            #expect(!QuickToggleID.darkMode.isOn(.absent))
            #expect(QuickToggleID.nightShift.isOn(.bool(true)))
        }

        @Test func restoreRecordsPriorState() {
            var book = QuickToggleRestoreBook()
            // Desktop icons were showing because the key was never set.
            let hide = book.turnOn(.hideDesktopIcons, current: .absent)
            #expect(hide == .bool(false))
            #expect(book.records[.hideDesktopIcons] == QuickToggleRestore(prior: .absent, applied: .bool(false)))
            // Turning it off puts back exactly that: the key removed, not CreateDesktop = true.
            let show = book.turnOff(.hideDesktopIcons, current: .bool(false))
            #expect(show == .absent)
            #expect(book.records[.hideDesktopIcons] == nil)

            // An explicit prior value comes back as that value.
            let on = book.turnOn(.showHiddenFiles, current: .bool(false))
            let off = book.turnOff(.showHiddenFiles, current: .bool(true))
            #expect(on == .bool(true))
            #expect(off == .bool(false))

            // Turning on twice keeps the first prior state.
            _ = book.turnOn(.hideDesktopIcons, current: .bool(true))
            _ = book.turnOn(.hideDesktopIcons, current: .bool(false))
            #expect(book.records[.hideDesktopIcons]?.prior == .bool(true))
            let back = book.turnOff(.hideDesktopIcons, current: .bool(false))
            #expect(back == .bool(true))
        }

        @Test func staleRecordFallsBackToPlainOff() {
            var book = QuickToggleRestoreBook()
            _ = book.turnOn(.showHiddenFiles, current: .bool(false))
            // Someone else changed the setting since (Terminal, another app): don't resurrect Orbit's memory.
            let stale = book.turnOff(.showHiddenFiles, current: .absent)
            #expect(stale == .absent)
            #expect(book.records.isEmpty)
            // Already on outside Orbit: turning "on" records nothing, so off can't restore "on".
            let unchanged = book.turnOn(.darkMode, current: .bool(true))
            #expect(unchanged == .bool(true))
            #expect(book.records[.darkMode] == nil)
            let light = book.turnOff(.darkMode, current: .bool(true))
            #expect(light == .bool(false))
            // Records survive a relaunch.
            _ = book.turnOn(.nightShift, current: .bool(false))
            let data = try? JSONEncoder().encode(book)
            #expect(data.flatMap { try? JSONDecoder().decode(QuickToggleRestoreBook.self, from: $0) } == book)
        }
    }
}

// MARK: - Eject

extension ControlsTests {
    @Suite struct EjectTests {
        private func volume(_ path: String, _ name: String, inside: Bool?, removable: Bool = false, ejectable: Bool = false,
                            local: Bool = true, root: Bool = false, browsable: Bool = true) -> VolumeInfo {
            VolumeInfo(path: path, name: name, isInternal: inside, isRemovable: removable, isEjectable: ejectable,
                       isLocal: local, isRootFileSystem: root, isBrowsable: browsable)
        }

        @Test func ejectableFiltersInternalAndNetwork() {
            // The volumes Kevo's Mac really had mounted (read-only probe), plus typical external ones.
            let mounted = [
                volume("/", "Macintosh HD", inside: true, root: true),
                volume("/System/Volumes/VM", "VM", inside: true, browsable: false),
                volume("/System/Volumes/Preboot", "Preboot", inside: true, browsable: false),
                volume("/System/Volumes/Data/home", "home", inside: nil, local: false, browsable: false),
                volume("/Library/Developer/CoreSimulator/Volumes/iOS_23F77", "iOS 26.5 Simulator", inside: nil,
                       removable: true, ejectable: true, browsable: false),
                volume("/Volumes/Backup SSD", "Backup SSD", inside: false, ejectable: true),
                volume("/Volumes/UNTITLED", "UNTITLED", inside: true, removable: true, ejectable: true),   // SD card slot
                volume("/Volumes/Install Foo", "Install Foo", inside: nil, removable: true, ejectable: true),   // disk image
                volume("/Volumes/Projects", "Projects", inside: nil, ejectable: true, local: false),            // SMB share
                volume("/Volumes/BOOTCAMP", "BOOTCAMP", inside: true),                                         // internal partition
            ]
            let names = EjectableVolumeFilter.ejectable(mounted).map(\.name)
            #expect(names == ["Backup SSD", "UNTITLED", "Install Foo"])
            // Unknown "internal" with no removable/ejectable evidence stays put.
            #expect(EjectableVolumeFilter.ejectable([volume("/Volumes/Mystery", "Mystery", inside: nil)]).isEmpty)
            // External but hidden from Finder: left alone.
            #expect(EjectableVolumeFilter.ejectable([volume("/Volumes/Hidden", "Hidden", inside: false, browsable: false)]).isEmpty)
            // Never the boot volume, whatever it claims.
            #expect(EjectableVolumeFilter.ejectable([volume("/Volumes/Boot", "Boot", inside: false, ejectable: true, root: true)]).isEmpty)
        }

        @Test func confirmationAndSummaryText() {
            let a = volume("/Volumes/Backup SSD", "Backup SSD", inside: false, ejectable: true)
            let b = volume("/Volumes/Install Foo", "Install Foo", inside: nil, ejectable: true)
            #expect(EjectableVolumeFilter.confirmation([a]) == "Eject “Backup SSD”?")
            #expect(EjectableVolumeFilter.confirmation([a, b]) == "Eject 2 drives?")
            #expect(EjectableVolumeFilter.summary(ejected: ["Backup SSD"], failed: []) == "Ejected “Backup SSD”")
            #expect(EjectableVolumeFilter.summary(ejected: ["A", "B"], failed: []) == "Ejected 2 drives")
            #expect(EjectableVolumeFilter.summary(ejected: [], failed: ["A"]) == "Couldn’t eject “A”")
            #expect(EjectableVolumeFilter.summary(ejected: ["A"], failed: ["B", "C"]) == "Ejected “A”; couldn’t eject 2 drives")
            #expect(EjectableVolumeFilter.summary(ejected: [], failed: []) == "No drives to eject")
        }
    }
}

// MARK: - Grab Text

extension ControlsTests {
    @Suite struct GrabTextTests {
        @Test func hudLineCounts() {
            let one = GrabTextResult.format(lines: ["Hello"])
            #expect(one.text == "Hello")
            #expect(one.hud == "Copied 1 line")
            let three = GrabTextResult.format(lines: ["  First line ", "", "Second", "Third\t"])
            #expect(three.text == "First line\nSecond\nThird")
            #expect(three.hud == "Copied 3 lines")
            let none = GrabTextResult.format(lines: ["", "   "])
            #expect(none.text.isEmpty)
            #expect(none.hud == "No text found")
            #expect(GrabTextResult.format(lines: []).hud == "No text found")
        }

        @Test func barcodeWins() {
            let qr = GrabTextResult.preferBarcode(payloads: ["https://example.com"], lines: ["Scan me", "example.com"])
            #expect(qr.text == "https://example.com")
            #expect(qr.hud == "Copied code")
            let two = GrabTextResult.preferBarcode(payloads: ["A", "B", "A", " "], lines: ["x"])
            #expect(two.text == "A\nB")                      // duplicates and blanks dropped, order kept
            #expect(two.hud == "Copied 2 codes")
            let text = GrabTextResult.preferBarcode(payloads: [], lines: ["Just text"])
            #expect(text.text == "Just text")
            #expect(text.hud == "Copied 1 line")
            #expect(GrabTextResult.preferBarcode(payloads: [""], lines: []).hud == "No text found")
        }

        /// Vision boxes are normalised with the origin at the bottom left; reading order is top to bottom,
        /// then left to right within a row.
        @Test func readingOrder() {
            let lines = [
                RecognizedLine(text: "right", box: CGRect(x: 0.6, y: 0.80, width: 0.3, height: 0.05)),
                RecognizedLine(text: "bottom", box: CGRect(x: 0.1, y: 0.10, width: 0.5, height: 0.05)),
                RecognizedLine(text: "left", box: CGRect(x: 0.1, y: 0.81, width: 0.3, height: 0.05)),
                RecognizedLine(text: "middle", box: CGRect(x: 0.1, y: 0.45, width: 0.5, height: 0.05)),
            ]
            #expect(GrabTextResult.readingOrder(lines) == ["left right", "middle", "bottom"])
            #expect(GrabTextResult.readingOrder([]) == [])
        }

        /// Two lines of black text on white, drawn with Core Text (what a screen capture of a page looks like).
        private func textImage(_ lines: [String]) -> CGImage {
            let width = 900, lineHeight = 70, height = lineHeight * lines.count + 60
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let font = CTFontCreateWithName("Helvetica" as CFString, 40, nil)
            for (i, line) in lines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1),
                ])
                ctx.textPosition = CGPoint(x: 40, y: CGFloat(height - 30 - lineHeight * (i + 1) + 20))
                CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            }
            return ctx.makeImage()!
        }

        @Test func recognizesRenderedText() throws {
            let output = try TextRecognizer.recognize(textImage(["Orbit grabs this text", "Second line here"]))
            #expect(output.payloads.isEmpty)
            #expect(output.lines.count == 2)
            #expect(output.lines.first?.lowercased().contains("orbit grabs") == true)
            #expect(output.lines.last?.lowercased().contains("second line") == true)
            #expect(GrabTextResult.preferBarcode(payloads: output.payloads, lines: output.lines).hud == "Copied 2 lines")
        }

        @Test func detectsQRPayload() throws {
            let dir = Fixtures.tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let url = Fixtures.qr("https://orbit.example/grab", in: dir)
            let image = try ImageFile.loadOriented(url)
            let output = try TextRecognizer.recognize(image)
            #expect(output.payloads == ["https://orbit.example/grab"])
            let result = GrabTextResult.preferBarcode(payloads: output.payloads, lines: output.lines)
            #expect(result.text == "https://orbit.example/grab")
            #expect(result.hud == "Copied code")
        }

        @Test func blankImageFindsNothing() throws {
            let output = try TextRecognizer.recognize(textImage([""]))
            #expect(output.lines.isEmpty)
            #expect(output.payloads.isEmpty)
        }
    }
}

// MARK: - Settings

extension ControlsTests {
    @Suite struct ControlsSettingsTests {
        @Test func settingsRoundTrip() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            let s = ControlsSettings(defaults: d)
            #expect(s.keepDisplayAwake == false)
            #expect(s.customDuration == 45 * 60)
            #expect(s.lastMode == nil)
            #expect(s.grabTextShortcut == .grabTextDefault)
            #expect(s.focusShortcutName == nil)
            #expect(s.visibleToggles == QuickToggleID.allCases)
            #expect(s.restoreBook == QuickToggleRestoreBook())

            let until = Date(timeIntervalSince1970: 1_800_000_000)
            var book = QuickToggleRestoreBook()
            _ = book.turnOn(.hideDesktopIcons, current: .absent)
            s.keepDisplayAwake = true
            s.customDuration = 90 * 60
            s.lastMode = .until(until)
            s.grabTextShortcut = KeyCombo(keyCode: 17, modifiers: [.control, .option])
            s.focusShortcutName = "Toggle Do Not Disturb"
            s.visibleToggles = [.micMute, .darkMode]
            s.restoreBook = book

            let r = ControlsSettings(defaults: d)
            #expect(r.keepDisplayAwake)
            #expect(r.customDuration == 90 * 60)
            #expect(r.lastMode == .until(until))
            #expect(r.grabTextShortcut == KeyCombo(keyCode: 17, modifiers: [.control, .option]))
            #expect(r.focusShortcutName == "Toggle Do Not Disturb")
            #expect(r.visibleToggles == [.darkMode, .micMute])   // always in grid order
            #expect(r.restoreBook == book)
            // Keys carry the feature prefix.
            #expect(d.object(forKey: "controls.keepDisplayAwake") as? Bool == true)
            #expect(d.data(forKey: "controls.grabTextShortcut") != nil)

            r.focusShortcutName = nil
            r.lastMode = nil
            #expect(ControlsSettings(defaults: d).focusShortcutName == nil)
            #expect(ControlsSettings(defaults: d).lastMode == nil)
        }

        @Test func badStoredValuesFallBack() {
            let (d, cleanup) = Fixtures.defaults()
            defer { cleanup() }
            d.set(Data("junk".utf8), forKey: "controls.grabTextShortcut")
            d.set(Data("junk".utf8), forKey: "controls.lastMode")
            d.set(["micMute", "teleporter"], forKey: "controls.visibleToggles")
            d.set(5.0, forKey: "controls.customDuration")
            d.set("   ", forKey: "controls.focusShortcutName")
            let s = ControlsSettings(defaults: d)
            #expect(s.grabTextShortcut == .grabTextDefault)
            #expect(s.lastMode == nil)
            #expect(s.visibleToggles == [.micMute])
            #expect(s.customDuration == 60)            // clamped to 1 min … 24 h
            #expect(s.focusShortcutName == nil)        // a blank name is no Shortcut
            s.customDuration = 100 * 3600
            #expect(ControlsSettings(defaults: d).customDuration == 24 * 3600)
        }
    }
}

// MARK: - Until-time picker and the Focus Shortcut

extension ControlsTests {
    @Suite struct ControlsHelperTests {
        /// "Until 07:00" picked at 22:00 means tomorrow morning; "until 23:30" picked at 22:00 means tonight.
        @Test func untilPicksNextOccurrence() {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: "UTC")!
            let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 22, minute: 0))!
            let tonight = KeepAwakeMode.nextOccurrence(hour: 23, minute: 30, after: now, calendar: cal)
            #expect(tonight == cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 23, minute: 30)))
            let morning = KeepAwakeMode.nextOccurrence(hour: 7, minute: 0, after: now, calendar: cal)
            #expect(morning == cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 7, minute: 0)))
            // The current minute itself is already past: it means tomorrow.
            let same = KeepAwakeMode.nextOccurrence(hour: 22, minute: 0, after: now, calendar: cal)
            #expect(same == cal.date(from: DateComponents(year: 2026, month: 10, day: 29, hour: 22, minute: 0)))
        }

        @Test func shortcutListParsing() {
            #expect(FocusShortcut.parseList("Send Message\n") == ["Send Message"])
            #expect(FocusShortcut.parseList("Toggle Do Not Disturb\n\n  Morning Focus  \nSend Message\nToggle Do Not Disturb\n")
                    == ["Morning Focus", "Send Message", "Toggle Do Not Disturb"])
            #expect(FocusShortcut.parseList("").isEmpty)
            #expect(FocusShortcut.runArguments("Toggle Do Not Disturb") == ["run", "Toggle Do Not Disturb"])
            #expect(FocusShortcut.executable.path == "/usr/bin/shortcuts")
        }
    }
}

// MARK: - Fix round 1 (task review)

extension ControlsTests {
    @Suite struct ControlsFixRound1Tests {
        private let start = Date(timeIntervalSince1970: 1_800_000_000)

        /// M1: a timer that fires before the wall-clock deadline (the clock was set back) must be re-armed
        /// for the deadline instead of leaving the assertion up forever.
        @Test func rearmsWhenTimerFiresEarly() {
            let s = KeepAwakeSession(startDate: start, mode: .duration(3600), keepDisplayAwake: false)
            #expect(s.nextCheck(now: start.addingTimeInterval(1800)) == start.addingTimeInterval(3600))
            #expect(s.nextCheck(now: start.addingTimeInterval(3600)) == nil)     // due: evaluate ends it
            #expect(s.nextCheck(now: start.addingTimeInterval(9999)) == nil)
            let until = KeepAwakeSession(startDate: start, mode: .until(start.addingTimeInterval(60)), keepDisplayAwake: false)
            #expect(until.nextCheck(now: start) == start.addingTimeInterval(60))
            // Sessions without a deadline have nothing to re-arm.
            #expect(KeepAwakeSession(startDate: start, mode: .indefinitely, keepDisplayAwake: false).nextCheck(now: start) == nil)
            #expect(KeepAwakeSession(startDate: start, mode: .whileDownloading, keepDisplayAwake: false).nextCheck(now: start) == nil)
        }

        /// M9: macOS can refuse the display assertion alone; the engine says so instead of pretending.
        @Test func engineReportsRefusedDisplayAssertion() {
            let fake = FakeAsserter()
            fake.refuseKinds = [.preventDisplaySleep]
            let engine = KeepAwakeEngine(asserter: fake)
            #expect(engine.start(.indefinitely, keepDisplayAwake: true, now: start))
            #expect(engine.isActive)
            #expect(engine.session?.keepDisplayAwake == true)      // what the user asked for
            #expect(!engine.holdsDisplayAssertion)                  // what macOS granted
            #expect(fake.held == [.preventSystemSleep])
            fake.refuseKinds = []
            engine.setKeepDisplayAwake(true)
            #expect(engine.holdsDisplayAssertion)
            engine.stop()
            #expect(!engine.holdsDisplayAssertion)
        }

        @Test func statusLineTellsTheTruth() {
            let s = KeepAwakeSession(startDate: start, mode: .duration(2 * 3600), keepDisplayAwake: true)
            let now = start.addingTimeInterval(48 * 60)
            #expect(KeepAwakeFormat.status(s, now: now, displayHeld: true) == "1 h 12 m left · display stays on")
            #expect(KeepAwakeFormat.status(s, now: now, displayHeld: false) == "1 h 12 m left · display can still sleep")
            let plain = KeepAwakeSession(startDate: start, mode: .indefinitely, keepDisplayAwake: false)
            #expect(KeepAwakeFormat.status(plain, now: now, displayHeld: false) == "Indefinitely")
            #expect(KeepAwakeFormat.status(nil, now: now, displayHeld: false) == "Off · your Mac sleeps as usual")
        }

        /// M3/M4: the panel showed a stale "on"; the setting is already off, so nothing is written (and
        /// Finder is not restarted for nothing).
        @Test func turnOffWhenAlreadyOffChangesNothing() {
            var book = QuickToggleRestoreBook()
            let a = book.turnOff(.hideDesktopIcons, current: .bool(true))
            #expect(a == .bool(true))
            let b = book.turnOff(.hideDesktopIcons, current: .absent)
            #expect(b == .absent)
            let c = book.turnOff(.showHiddenFiles, current: .bool(false))
            #expect(c == .bool(false))
            // A leftover record for a setting that's already off is dropped, not replayed.
            _ = book.turnOn(.showHiddenFiles, current: .absent)
            let d = book.turnOff(.showHiddenFiles, current: .bool(false))
            #expect(d == .bool(false))
            #expect(book.records.isEmpty)
        }

        /// M2: two toggles in flight each commit their own record against the latest book.
        @Test func concurrentChangesKeepBothRecords() {
            var book = QuickToggleRestoreBook()
            let desktop = book.change(.hideDesktopIcons, on: true, current: .absent)
            let hidden = book.change(.showHiddenFiles, on: true, current: .bool(false))
            #expect(desktop.write == .bool(false))
            #expect(hidden.write == .bool(true))
            #expect(book.records.isEmpty)          // planning changes nothing
            book.commit(.showHiddenFiles, hidden)   // finishes first
            book.commit(.hideDesktopIcons, desktop)
            #expect(book.records[.hideDesktopIcons] == QuickToggleRestore(prior: .absent, applied: .bool(false)))
            #expect(book.records[.showHiddenFiles] == QuickToggleRestore(prior: .bool(false), applied: .bool(true)))
        }

        /// M13: turning Dark Mode on while the appearance is Auto turns Auto off (so the choice sticks) and
        /// remembers it; turning Dark Mode off brings Auto back.
        @Test func darkModeRestoresAuto() {
            var book = QuickToggleRestoreBook()
            let on = book.change(.darkMode, on: true, current: .bool(false), automatic: true)
            #expect(on.write == .bool(true))
            #expect(on.automatic == false)
            #expect(on.record?.priorAutomatic == true)
            book.commit(.darkMode, on)
            let off = book.change(.darkMode, on: false, current: .bool(true), automatic: false)
            #expect(off.write == .bool(false))
            #expect(off.automatic == true)
            book.commit(.darkMode, off)
            #expect(book.records.isEmpty)
            // Not on Auto before: Auto is left alone both ways.
            let manual = book.change(.darkMode, on: true, current: .bool(false), automatic: false)
            #expect(manual.automatic == nil)
            book.commit(.darkMode, manual)
            #expect(book.change(.darkMode, on: false, current: .bool(true), automatic: false).automatic == nil)
            // Old records (saved before priorAutomatic existed) still decode.
            let legacy = Data(#"{"prior":{"absent":{}},"applied":{"bool":{"_0":false}}}"#.utf8)
            #expect((try? JSONDecoder().decode(QuickToggleRestore.self, from: legacy))?.priorAutomatic == nil)
        }

        /// M6: network mounts are dropped from the mount table before any resource value is read, so a
        /// stale SMB/NFS share can't stall the listing.
        @Test func skipsNetworkMountsBeforeReadingThem() {
            let mounts = [
                MountEntry(path: "/", isLocal: true),
                MountEntry(path: "/System/Volumes/Data", isLocal: true),
                MountEntry(path: "/Volumes/Backup SSD", isLocal: true),
                MountEntry(path: "/Volumes/Projects", isLocal: false),           // SMB
                MountEntry(path: "/Volumes/NAS", isLocal: false),                // NFS
                MountEntry(path: "/Library/Developer/CoreSimulator/Volumes/iOS_23F77", isLocal: true),
                MountEntry(path: "/Volumes/Install Foo", isLocal: true),
            ]
            #expect(EjectableVolumeFilter.worthInspecting(mounts) == ["/Volumes/Backup SSD", "/Volumes/Install Foo"])
        }

        /// M7: the Do Not Disturb Shortcut can't hang the button: runs are cut off after a timeout.
        @Test func shortcutRunTimesOut() async throws {
            #expect(FocusShortcut.timeout == 15)
            let fast = try await FocusShortcut.withTimeout(5) { 42 }
            #expect(fast == 42)
            let began = Date()
            await #expect(throws: FocusShortcut.TimedOut.self) {
                try await FocusShortcut.withTimeout(0.2) { try await Task.sleep(for: .seconds(30)) }
            }
            #expect(Date().timeIntervalSince(began) < 5)
            // A real process is terminated when the timeout cancels it.
            let processBegan = Date()
            await #expect(throws: (any Error).self) {
                try await FocusShortcut.withTimeout(0.3) {
                    try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), ["30"])
                }
            }
            #expect(Date().timeIntervalSince(processBegan) < 15)
        }

        /// I1: after the crosshair closes, focus goes back to the app the user was in.
        @Test func focusGoesBackAfterOverlay() {
            #expect(GrabTextFocus.afterOverlay(previousWasOrbit: false, orbitIsActive: true, previousAvailable: true) == .activatePrevious)
            #expect(GrabTextFocus.afterOverlay(previousWasOrbit: false, orbitIsActive: true, previousAvailable: false) == .hideOrbit)
            // The overlay never took focus (non-activating panel): nothing to give back.
            #expect(GrabTextFocus.afterOverlay(previousWasOrbit: false, orbitIsActive: false, previousAvailable: true) == .none)
            // Orbit was already in front (Settings open): leave it there.
            #expect(GrabTextFocus.afterOverlay(previousWasOrbit: true, orbitIsActive: true, previousAvailable: true) == .none)
        }
    }
}
