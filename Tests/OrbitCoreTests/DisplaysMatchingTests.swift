import Foundation
import Testing
@testable import OrbitCore

/// Matching DDC services (IORegistry) to displays (CoreGraphics). Fixtures are Kevo's Mac on 2026-10-28:
/// two ThinkVision P27u-20 with one EDID UUID and serial 0, an AOC Q27G4ZD and an Acer K272HUL.
@Suite struct DDCServiceMatcherTests {
    static let root = "IOService:/AppleARMPE/arm-io@10F00000/AppleSoCIO"
    static func framebuffer(_ unit: String) -> String { "\(root)/\(unit)/IOMobileFramebufferShim" }

    static let thinkVisionUUID = "30AECB62-0000-0000-1E24-0104B53C2278"

    /// Services in IORegistry order (dispext0...3).
    static let kevosServices = [
        AVServiceDescriptor(framebufferPath: framebuffer("dispext0@B0000000"), edidUUID: thinkVisionUUID, productName: "P27u-20",
                            vendorID: 12462, productID: 25291, serialNumber: 0, alphanumericSerial: "V90GFKY1",
                            yearOfManufacture: 2026, weekOfManufacture: 30),
        AVServiceDescriptor(framebufferPath: framebuffer("dispext1@90000000"), edidUUID: "04722405-0000-0000-201A-0104B53C2278",
                            productName: "K272HUL", vendorID: 1138, productID: 1316, serialNumber: 1_663_094_707,
                            alphanumericSerial: "T6AAA0048522", yearOfManufacture: 2016, weekOfManufacture: 32),
        AVServiceDescriptor(framebufferPath: framebuffer("dispext2@0"), edidUUID: thinkVisionUUID, productName: "P27u-20",
                            vendorID: 12462, productID: 25291, serialNumber: 0, alphanumericSerial: "V90GFKXY",
                            yearOfManufacture: 2026, weekOfManufacture: 30),
        AVServiceDescriptor(framebufferPath: framebuffer("dispext3@4000000"), edidUUID: "05E321B4-0000-0000-0D23-0104B53B2178",
                            productName: "Q27G4ZD", vendorID: 1507, productID: 46113, serialNumber: 11320,
                            alphanumericSerial: "2OMR3JA011320", yearOfManufacture: 2025, weekOfManufacture: 13),
    ]

    /// Displays in CGGetOnlineDisplayList order (ids 2, 3, 4, 5). CoreGraphics has no alphanumeric serial.
    static let kevosDisplays = [
        DisplayDescriptor(vendorID: 12462, productID: 25291, serialNumber: 0, productName: "P27u-20",
                          ioDisplayLocation: framebuffer("dispext2@0"), yearOfManufacture: 2026, weekOfManufacture: 30),
        DisplayDescriptor(vendorID: 1507, productID: 46113, serialNumber: 11320, productName: "Q27G4ZD",
                          ioDisplayLocation: framebuffer("dispext3@4000000"), yearOfManufacture: 2025, weekOfManufacture: 13),
        DisplayDescriptor(vendorID: 12462, productID: 25291, serialNumber: 0, productName: "P27u-20",
                          ioDisplayLocation: framebuffer("dispext0@B0000000"), yearOfManufacture: 2026, weekOfManufacture: 30),
        DisplayDescriptor(vendorID: 1138, productID: 1316, serialNumber: 1_663_094_707, productName: "K272HUL",
                          ioDisplayLocation: framebuffer("dispext1@90000000"), yearOfManufacture: 2016, weekOfManufacture: 32),
    ]

    @Test func matchesKevosFourMonitorsByLocation() {
        let match = DDCServiceMatcher.match(services: Self.kevosServices, displays: Self.kevosDisplays)
        // dispext0 → id 4, dispext1 → id 5 (Acer), dispext2 → id 2 (main ThinkVision), dispext3 → id 3 (AOC).
        #expect(match == [0: 2, 1: 3, 2: 0, 3: 1])
    }

    @Test func twoIdenticalMonitorsDifferOnlyBySerial() {
        // No locations (another macOS, or CoreDisplay missing): same EDID UUID, vendor, product, name, date;
        // only the serials differ, and the display list is in the opposite order.
        let a = AVServiceDescriptor(edidUUID: Self.thinkVisionUUID, productName: "P27u-20", vendorID: 12462, productID: 25291,
                                    serialNumber: 1111, yearOfManufacture: 2026, weekOfManufacture: 30)
        var b = a
        b.serialNumber = 2222
        let displayB = DisplayDescriptor(vendorID: 12462, productID: 25291, serialNumber: 2222, productName: "P27u-20",
                                         yearOfManufacture: 2026, weekOfManufacture: 30)
        var displayA = displayB
        displayA.serialNumber = 1111
        #expect(DDCServiceMatcher.match(services: [a, b], displays: [displayB, displayA]) == [0: 1, 1: 0])
        // The same with alphanumeric serials (numeric 0 on both).
        var c = a; c.serialNumber = 0; c.alphanumericSerial = "V90GFKY1"
        var d = a; d.serialNumber = 0; d.alphanumericSerial = "V90GFKXY"
        var displayC = displayA; displayC.serialNumber = 0; displayC.alphanumericSerial = "V90GFKY1"
        var displayD = displayA; displayD.serialNumber = 0; displayD.alphanumericSerial = "v90gfkxy"
        #expect(DDCServiceMatcher.match(services: [c, d], displays: [displayD, displayC]) == [0: 1, 1: 0])
        // A known serial that differs rules a pair out.
        #expect(DDCServiceMatcher.score(a, displayB) == nil)
        #expect(DDCServiceMatcher.score(a, displayA) != nil)
    }

    @Test func eliminationAssignsTheRemainingIdenticalMonitor() {
        // Only one of the two identical monitors can be told apart; the other must take what's left even
        // though list order would pair it the other way.
        let plain = AVServiceDescriptor(productName: "P27u-20", vendorID: 12462, productID: 25291, serialNumber: 0)
        var known = plain
        known.alphanumericSerial = "V90GFKXY"
        let displayPlain = DisplayDescriptor(vendorID: 12462, productID: 25291, serialNumber: 0, productName: "P27u-20")
        var displayKnown = displayPlain
        displayKnown.alphanumericSerial = "V90GFKXY"
        #expect(DDCServiceMatcher.match(services: [plain, known], displays: [displayKnown, displayPlain]) == [0: 1, 1: 0])
        // A service with one possible display is paired with it even when another service scores that
        // display higher (best-score-first alone would leave `serialOnly` with nothing).
        let named = AVServiceDescriptor(productName: "Q27G4ZD", vendorID: 1507, productID: 46113)
        let serialOnly = AVServiceDescriptor(vendorID: 1507, productID: 46113, serialNumber: 777)
        let namedDisplay = DisplayDescriptor(vendorID: 1507, productID: 46113, productName: "Q27G4ZD")
        let otherSerial = DisplayDescriptor(vendorID: 1507, productID: 46113, serialNumber: 555)
        #expect(DDCServiceMatcher.score(named, namedDisplay)! > DDCServiceMatcher.score(named, otherSerial)!)
        #expect(DDCServiceMatcher.score(serialOnly, otherSerial) == nil)
        #expect(DDCServiceMatcher.match(services: [named, serialOnly], displays: [namedDisplay, otherSerial]) == [0: 1, 1: 0])
    }

    @Test func locationsDecideOnlyWhenComparable() {
        // A location that matches exactly beats every other fact.
        let services = Self.kevosServices
        #expect(DDCServiceMatcher.score(services[0], Self.kevosDisplays[2])! > DDCServiceMatcher.score(services[0], Self.kevosDisplays[0], locationsComparable: false)!)
        // A comparable location that differs rules the pair out...
        #expect(DDCServiceMatcher.score(services[0], Self.kevosDisplays[0]) == nil)
        // ...but if no pair matches by location (a different path format), locations are ignored and the
        // EDID facts decide: the Acer and AOC still match, the ThinkVisions fall back to list order.
        let reformatted = Self.kevosDisplays.map { display -> DisplayDescriptor in
            var copy = display
            copy.ioDisplayLocation = copy.ioDisplayLocation.map { "/" + $0.replacingOccurrences(of: "IOService:/", with: "") + "/x" }
            return copy
        }
        let match = DDCServiceMatcher.match(services: services, displays: reformatted)
        #expect(match[1] == 3)
        #expect(match[3] == 1)
        #expect(Set([match[0], match[2]]) == Set([0, 2]))
        // "IOService:" prefixes are ignored when comparing.
        var bare = Self.kevosDisplays
        bare[2].ioDisplayLocation = "/AppleARMPE/arm-io@10F00000/AppleSoCIO/dispext0@B0000000/IOMobileFramebufferShim"
        #expect(DDCServiceMatcher.match(services: services, displays: bare)[0] == 2)
    }

    @Test func neverMatchesTheWrongKindOfDisplay() {
        let tv = Self.kevosServices[0]
        // The built-in display has no external AV service.
        #expect(DDCServiceMatcher.score(tv, DisplayDescriptor(vendorID: 12462, productID: 25291, isBuiltIn: true)) == nil)
        // Different vendor or product.
        #expect(DDCServiceMatcher.score(tv, DisplayDescriptor(vendorID: 1507, productID: 25291)) == nil)
        #expect(DDCServiceMatcher.score(tv, DisplayDescriptor(vendorID: 12462, productID: 1)) == nil)
        // A service with no display left over stays unmatched; nothing is paired twice.
        let match = DDCServiceMatcher.match(services: Self.kevosServices, displays: [Self.kevosDisplays[1]])
        #expect(match == [3: 0])
        #expect(DDCServiceMatcher.match(services: [], displays: Self.kevosDisplays).isEmpty)
        #expect(DDCServiceMatcher.match(services: Self.kevosServices, displays: []).isEmpty)
        // With nothing to tell two identical monitors apart, list order is the (documented) guess.
        let blank = AVServiceDescriptor(vendorID: 12462, productID: 25291)
        let blankDisplay = DisplayDescriptor(vendorID: 12462, productID: 25291)
        #expect(DDCServiceMatcher.match(services: [blank, blank], displays: [blankDisplay, blankDisplay]) == [0: 0, 1: 1])
    }

    @Test func decodesEDIDUUIDs() {
        let tv = EDIDUUID(Self.thinkVisionUUID)
        #expect(tv == EDIDUUID(vendorID: 0x30AE, productID: 25291, weekOfManufacture: 30, yearOfManufacture: 2026))
        #expect(EDIDUUID("04722405-0000-0000-201A-0104B53C2278") == EDIDUUID(vendorID: 1138, productID: 1316, weekOfManufacture: 32, yearOfManufacture: 2016))
        #expect(EDIDUUID("05e321b4-0000-0000-0d23-0104b53b2178")?.productID == 46113)
        #expect(EDIDUUID("") == nil)
        #expect(EDIDUUID("30AECB62-0000") == nil)
        #expect(EDIDUUID("ZZAECB62-0000-0000-1E24-0104B53C2278") == nil)
    }

    @Test func buildsDescriptorsFromRegistryAndCoreDisplay() {
        // The framebuffer's properties as IORegistry returns them (trimmed).
        let properties: [String: Any] = [
            "EDID UUID": Self.thinkVisionUUID,
            "DisplayAttributes": ["MaximumRefreshRate": 70,
                                  "ProductAttributes": ["YearOfManufacture": 2026, "ManufacturerID": "LEN", "SerialNumber": 0,
                                                        "ProductName": "P27u-20", "AlphanumericSerialNumber": "V90GFKY1",
                                                        "LegacyManufacturerID": 12462, "ProductID": 25291, "WeekOfManufacture": 30]] as [String: Any],
        ]
        let path = Self.framebuffer("dispext0@B0000000")
        #expect(AVServiceDescriptor(framebufferPath: path, properties: properties) == Self.kevosServices[0])
        // Without DisplayAttributes, the EDID UUID still gives vendor, product and date.
        let bare = AVServiceDescriptor(framebufferPath: path, properties: ["EDID UUID": Self.thinkVisionUUID])
        #expect(bare == AVServiceDescriptor(framebufferPath: path, edidUUID: Self.thinkVisionUUID, vendorID: 12462, productID: 25291,
                                            yearOfManufacture: 2026, weekOfManufacture: 30))
        #expect(AVServiceDescriptor(framebufferPath: nil, properties: [:]) == AVServiceDescriptor())

        // CoreDisplay's info dictionary (trimmed).
        let info: [String: Any] = [
            "IODisplayLocation": Self.framebuffer("dispext2@0"),
            "DisplayProductName": ["de_DE": "P27u-20 (de)", "en_US": "P27u-20"],
            "DisplayYearManufacture": 2026, "DisplayWeekManufacture": 30, "DisplaySerialNumber": 0,
        ]
        #expect(DisplayDescriptor(vendor: 12462, model: 25291, serial: 0, isBuiltIn: false, info: info) == Self.kevosDisplays[0])
        let noInfo = DisplayDescriptor(vendor: 1507, model: 46113, serial: 11320, isBuiltIn: false, info: nil)
        #expect(noInfo == DisplayDescriptor(vendorID: 1507, productID: 46113, serialNumber: 11320))
        // Some other localization when there's no en_US.
        let french = DisplayDescriptor(vendor: 1, model: 2, serial: 0, isBuiltIn: true, info: ["DisplayProductName": ["fr_FR": "Écran"]])
        #expect(french.productName == "Écran")
        #expect(french.isBuiltIn)
    }

    @Test func pairsServicesWithTheirFramebuffers() {
        // The real walk order: the built-in framebuffer, then each external framebuffer before its service.
        let entries: [AVServicePairing.Entry] = [
            .init(.framebuffer, path: Self.framebuffer("disp0@88000000")),
            .init(.framebuffer, path: Self.framebuffer("dispext0@B0000000")),
            .init(.service(external: true), path: "\(Self.root)/dcpext0@B2E00000/AppleASCWrapV6/iop-dcpext0-nub/RTBuddy(DCPEXT0)/DCPEXT0Endpoint11/AFKDCPEXT0Endpoint11/AFKEPInterfaceServiceKextV2/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"),
            .init(.framebuffer, path: Self.framebuffer("dispext1@90000000")),
            .init(.service(external: true), path: "\(Self.root)/dcpext1@92E00000/AppleASCWrapV6/iop-dcpext1-nub/RTBuddy(DCPEXT1)/DCPEXT1Endpoint11/AFKDCPEXT1Endpoint11/AFKEPInterfaceServiceKextV2/dispext1:dcpav-service-epic:0/DCPAVServiceProxy"),
            .init(.service(external: false), path: "\(Self.root)/dcp@88E00000/disp0:dcpav-service-epic:0/DCPAVServiceProxy"),
        ]
        #expect(AVServicePairing.pair(entries) == [2: 1, 4: 3])
        // Units are matched by name even when the walk order is unhelpful...
        let shuffled: [AVServicePairing.Entry] = [
            .init(.framebuffer, path: Self.framebuffer("dispext1@90000000")),
            .init(.framebuffer, path: Self.framebuffer("dispext0@B0000000")),
            .init(.service(external: true), path: "\(Self.root)/x/dispext1:dcpav-service-epic:0/DCPAVServiceProxy"),
        ]
        #expect(AVServicePairing.pair(shuffled) == [2: 0])
        // ...and by order when the paths carry no unit name (older layouts).
        let anonymous: [AVServicePairing.Entry] = [
            .init(.service(external: true), path: "IOService:/a/DCPAVServiceProxy"),          // nothing before it
            .init(.framebuffer, path: "IOService:/a/b/AppleCLCD2"),
            .init(.service(external: true), path: "IOService:/a/c/DCPAVServiceProxy"),
        ]
        #expect(AVServicePairing.pair(anonymous) == [2: 1])
        // Order never overrides a unit name: dispext4's service with only dispext0's framebuffer before it
        // stays unpaired (its display falls back to software dimming rather than talking to the wrong one).
        let mismatched: [AVServicePairing.Entry] = [
            .init(.framebuffer, path: Self.framebuffer("dispext0@B0000000")),
            .init(.service(external: true), path: "\(Self.root)/x/dispext4:dcpav-service-epic:0/DCPAVServiceProxy"),
        ]
        #expect(AVServicePairing.pair(mismatched).isEmpty)
        #expect(AVServicePairing.unitToken(in: Self.framebuffer("dispext12@B0000000")) == "dispext12")
        #expect(AVServicePairing.unitToken(in: "\(Self.root)/x/disp0:dcpav-service-epic:0/DCPAVServiceProxy") == "disp0")
        #expect(AVServicePairing.unitToken(in: "IOService:/a/b/AppleCLCD2") == nil)
        #expect(AVServicePairing.unitToken(in: "\(Self.root)/display@1/x") == nil)
    }
}
