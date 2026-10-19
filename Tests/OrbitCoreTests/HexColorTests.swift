import Foundation
import Testing
@testable import OrbitCore

@Suite struct HexColorTests {
    @Test func parsesSixDigits() throws {
        let c = try #require(HexColor.parse("80649C"))
        #expect(c == RGBA(r: 128.0 / 255, g: 100.0 / 255, b: 156.0 / 255, a: 1))
    }

    @Test func acceptsLowercaseAndHash() throws {
        let upper = try #require(HexColor.parse("80649C"))
        #expect(HexColor.parse("80649c") == upper)
        #expect(HexColor.parse("#80649C") == upper)
        #expect(HexColor.parse("#80649c") == upper)
    }

    @Test func extremes() throws {
        #expect(HexColor.parse("000000") == RGBA(r: 0, g: 0, b: 0, a: 1))
        #expect(HexColor.parse("FFFFFF") == RGBA(r: 1, g: 1, b: 1, a: 1))
    }

    @Test(arguments: ["", "#", "80649", "80649CC", "GGGGGG", "80 649C", "#80649", "##80649C", "+80649C", "８０６４９C", "80649C "])
    func rejectsInvalid(_ text: String) {
        #expect(HexColor.parse(text) == nil)
    }

    @Test func formatsUppercaseWithoutHash() {
        #expect(HexColor.format(RGBA(r: 1, g: 0, b: 0, a: 0.3)) == "FF0000")
        #expect(HexColor.format(RGBA(r: 128.0 / 255, g: 100.0 / 255, b: 156.0 / 255, a: 1)) == "80649C")
    }

    @Test func formatClampsOutOfRange() {
        #expect(HexColor.format(RGBA(r: -1, g: 2, b: 0.5, a: 1)) == "00FF80")
    }

    @Test(arguments: ["80649C", "000000", "FFFFFF", "0A1B2C", "FF5C1A"])
    func roundTrips(_ hex: String) throws {
        #expect(HexColor.format(try #require(HexColor.parse(hex))) == hex)
    }
}

@Suite struct AccentSettingTests {
    private func suite() -> (UserDefaults, () -> Void) {
        let name = "orbit-test-\(UUID())"
        let d = UserDefaults(suiteName: name)!
        return (d, { d.removePersistentDomain(forName: name) })
    }

    @Test func defaultIsOrbitPurple() {
        let (d, clean) = suite(); defer { clean() }
        #expect(SettingsStore(defaults: d).accentHex == "80649C")
        #expect(SettingsStore.defaultAccentHex == "80649C")
    }

    @Test func persistsAndNormalises() {
        let (d, clean) = suite(); defer { clean() }
        let s = SettingsStore(defaults: d)
        s.accentHex = "#ff5c1a"
        #expect(s.accentHex == "FF5C1A")
        #expect(SettingsStore(defaults: d).accentHex == "FF5C1A")
    }

    @Test func rejectsInvalidAssignment() {
        let (d, clean) = suite(); defer { clean() }
        let s = SettingsStore(defaults: d)
        s.accentHex = "11AA22"
        s.accentHex = "banana"
        #expect(s.accentHex == "80649C")
        #expect(SettingsStore(defaults: d).accentHex == "80649C")
    }

    @Test func rejectsInvalidStoredValue() {
        let (d, clean) = suite(); defer { clean() }
        d.set("not-a-colour", forKey: "accentHex")
        #expect(SettingsStore(defaults: d).accentHex == "80649C")
    }
}
