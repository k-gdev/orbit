import Testing
import Foundation
@testable import OrbitCore

@Test func customFFmpegWins() { let l = HelperLocator(isExecutable: { _ in true }, appInstalled: { _ in false })
    #expect(l.locate(customFFmpegPath: "/opt/x/ffmpeg").ffmpeg?.path == "/opt/x/ffmpeg") }
@Test func homebrewThenUsrLocal() { let l = HelperLocator(isExecutable: { $0 == "/usr/local/bin/ffmpeg" }, appInstalled: { _ in false })
    #expect(l.locate(customFFmpegPath: nil).ffmpeg?.path == "/usr/local/bin/ffmpeg") }
@Test func noFFmpeg() { #expect(HelperLocator(isExecutable: { _ in false }, appInstalled: { _ in false }).locate(customFFmpegPath: nil).ffmpeg == nil) }
@Test func oldIWorkIDFallback() { let l = HelperLocator(isExecutable: { _ in false }, appInstalled: { $0 == "com.apple.iWork.Pages" })
    #expect(l.locate(customFFmpegPath: nil).pagesBundleID == "com.apple.iWork.Pages") }
@Test func newIWorkIDPreferred() { let l = HelperLocator(isExecutable: { _ in false }, appInstalled: { _ in true })
    #expect(l.locate(customFFmpegPath: nil).keynoteBundleID == "com.apple.Keynote") }
@Test func settingsDefaultsAndPersistence() { let d = UserDefaults(suiteName: "orbit-test-\(UUID())")!
    let s = SettingsStore(defaults: d); #expect(s.pdfDPI == 300); #expect(s.videoFitPresets.first == 10_000_000)
    s.terminalBundleID = "com.googlecode.iterm2"; #expect(SettingsStore(defaults: d).terminalBundleID == "com.googlecode.iterm2") }

@Test func settingsRoundTripAllTypes() {
    let name = "orbit-test-\(UUID())"
    let d = UserDefaults(suiteName: name)!
    defer { d.removePersistentDomain(forName: name) }
    let s = SettingsStore(defaults: d)
    #expect(s.favouriteFolders.count == 3)
    s.favouriteFolders = [URL(fileURLWithPath: "/tmp/a b", isDirectory: true)]
    s.imageFitPresets = [123]
    s.jpegQuality = 0.5
    s.pdfDPI = 150
    s.customFFmpegPath = "/x/ffmpeg"
    s.isEnabled = false
    let r = SettingsStore(defaults: d)
    #expect(r.favouriteFolders.map(\.path) == ["/tmp/a b"])
    #expect(r.imageFitPresets == [123])
    #expect(r.jpegQuality == 0.5 && r.pdfDPI == 150 && r.isEnabled == false)
    #expect(r.customFFmpegPath == "/x/ffmpeg")
    r.customFFmpegPath = nil
    #expect(SettingsStore(defaults: d).customFFmpegPath == nil)
}

@Test func capabilitiesHas() {
    #expect(Capabilities.everything.has(.ffmpeg) && Capabilities.everything.has(.numbers))
    #expect(!Capabilities.none.has(.pages))
    #expect(Capabilities.everything.bundleID(for: .keynote) == "com.apple.Keynote")
}
