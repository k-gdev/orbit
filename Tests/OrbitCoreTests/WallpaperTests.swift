import Foundation
import Testing
@testable import OrbitCore

// MARK: - Fixtures

/// A cut-down copy of the macOS 26 aerial manifest (`com.apple.wallpaper/aerials/manifest/entries.json`), with the
/// same keys the real file uses: `assets[].id/accessibilityLabel/localizedNameKey/categories/shotID/...` and the
/// top-level `categories` that name them.
enum WallpaperFixtures {
    static let tahoe = "4C108785-A7BA-422E-9C79-B0129F1D5550"
    static let oregon = "8A57476A-E177-4AAD-B317-643F681584E1"
    static let jellies = "C7AD3D0A-7EDF-412C-A237-B3C9D27381A1"
    static let labelOnly = "0F0F0F0F-0000-4000-8000-000000000001"
    static let landscapes = "A33A55D9-EDEA-4596-A850-6C10B54FBBB5"
    static let underwater = "8BE8B524-6EAE-43F5-A3E8-01DCFA1BCD4B"

    static let entriesJSON = Data("""
    {
      "assets": [
        {
          "accessibilityLabel": "Alaskan Jellies",
          "categories": ["\(underwater)"],
          "id": "\(jellies)",
          "includeInShuffle": true,
          "localizedNameKey": "A003_C014_NAME",
          "pointsOfInterest": {"0": "A003_C014_0"},
          "preferredOrder": 1,
          "previewImage": "https://example.invalid/A003_C014.png",
          "shotID": "A003_C014",
          "showInTopLevel": true,
          "subcategories": ["1345CAE7-E0B1-455E-B255-025188356E42"],
          "url-4K-SDR-240FPS": "https://example.invalid/A003_C014.mov"
        },
        {
          "accessibilityLabel": "China Beach, Curry County, Oregon",
          "categories": ["\(landscapes)"],
          "group": "21J-1",
          "id": "\(oregon)",
          "includeInShuffle": true,
          "localizedNameKey": "R006_C013_S05_NAME",
          "pointsOfInterest": {"0": "R006_C013_0"},
          "preferredOrder": 27,
          "previewImage": "https://example.invalid/R006_C013_S05.png",
          "shotID": "R006_C013_S05",
          "showInTopLevel": true,
          "subcategories": ["2B044BC4-2E4F-4153-B951-66E5F8EA2C60"],
          "url-4K-SDR-240FPS": "https://example.invalid/R006_C013_S05.mov"
        },
        {
          "accessibilityLabel": "Tahoe Day",
          "categories": ["\(landscapes)"],
          "id": "\(tahoe)",
          "includeInShuffle": true,
          "localizedNameKey": "TA_L_002_NAME",
          "pointsOfInterest": {},
          "preferredOrder": 1,
          "previewImage": "https://example.invalid/TA_L_002_thumbnail.png",
          "shotID": "TA_L_002",
          "showInTopLevel": true,
          "subcategories": ["0DC99DD8-3386-4D1E-8878-C43E97EB710A"],
          "url-4K-SDR-240FPS": "https://example.invalid/TA_L_002.mov"
        },
        {
          "accessibilityLabel": "Fixture Label Only",
          "categories": ["11111111-2222-3333-4444-555555555555"],
          "id": "\(labelOnly)",
          "localizedNameKey": "NOT_IN_THE_STRINGS",
          "preferredOrder": 3,
          "shotID": "FX_001"
        }
      ],
      "categories": [
        {
          "id": "\(underwater)",
          "localizedDescriptionKey": "AerialCategoryUnderwaterDescription",
          "localizedNameKey": "AerialCategoryUnderwater",
          "preferredOrder": 2,
          "representativeAssetID": "\(jellies)",
          "subcategories": []
        },
        {
          "id": "\(landscapes)",
          "localizedDescriptionKey": "AerialCategoryLandscapesDescription",
          "localizedNameKey": "AerialCategoryLandscapes",
          "preferredOrder": 0,
          "representativeAssetID": "\(tahoe)",
          "subcategories": []
        }
      ],
      "initialAssetCount": 4,
      "localizationVersion": "22L-1",
      "version": 1
    }
    """.utf8)

    /// What `TVIdleScreenStrings.bundle` resolves those keys to in English.
    static let strings: [String: String] = [
        "TA_L_002_NAME": "Tahoe Day",
        "R006_C013_S05_NAME": "Oregon Sunset",
        "A003_C014_NAME": "Alaskan Jellies Light",
        "AerialCategoryLandscapes": "Landscape",
        "AerialCategoryUnderwater": "Underwater",
    ]

    /// A binary-plist `.loctable` like the real `Localizable.nocache.loctable`: one dictionary per locale.
    static func locTable(_ locales: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: locales, format: .binary, options: 0)
    }

    /// Lays out the macOS 26 aerials folder under `home` (`Library/Application Support/com.apple.wallpaper/aerials`)
    /// with the fixture manifest, an English loctable, and the given videos (id → byte count) and thumbnails.
    static func aerialsFolder(in home: URL, videos: [String: Int], thumbnails: [String]) throws -> URL {
        let root = home.appending(path: "Library/Application Support/com.apple.wallpaper/aerials", directoryHint: .isDirectory)
        let fm = FileManager.default
        let resources = root.appending(path: "manifest/TVIdleScreenStrings.bundle/Contents/Resources", directoryHint: .isDirectory)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        try entriesJSON.write(to: root.appending(path: "manifest/entries.json"), options: .withoutOverwriting)
        try locTable(["en": strings]).write(to: resources.appending(path: "Localizable.nocache.loctable"), options: .withoutOverwriting)
        try fm.createDirectory(at: root.appending(path: "videos", directoryHint: .isDirectory), withIntermediateDirectories: true)
        for (id, bytes) in videos {
            try Data(repeating: 0, count: bytes).write(to: root.appending(path: "videos/\(id).mov"), options: .withoutOverwriting)
        }
        try fm.createDirectory(at: root.appending(path: "thumbnails", directoryHint: .isDirectory), withIntermediateDirectories: true)
        for id in thumbnails {
            try Data([0x89, 0x50, 0x4E, 0x47]).write(to: root.appending(path: "thumbnails/\(id).png"), options: .withoutOverwriting)
        }
        return root
    }
}

// MARK: - Aerial catalog

@Suite struct AerialCatalogTests {
    @Test func parsesEntriesJSON() {
        let aerials = AerialCatalog.parse(entriesJSON: WallpaperFixtures.entriesJSON, localizedStrings: [:])
        #expect(Set(aerials.map(\.id)) == [WallpaperFixtures.tahoe, WallpaperFixtures.oregon, WallpaperFixtures.jellies,
                                           WallpaperFixtures.labelOnly])
        // No strings: every name falls back to the accessibility label.
        let byID = Dictionary(uniqueKeysWithValues: aerials.map { ($0.id, $0) })
        #expect(byID[WallpaperFixtures.oregon]?.name == "China Beach, Curry County, Oregon")
        #expect(byID[WallpaperFixtures.tahoe]?.name == "Tahoe Day")
        // Without strings the category still groups, named after its key.
        #expect(byID[WallpaperFixtures.tahoe]?.category == "Landscapes")
        #expect(byID[WallpaperFixtures.jellies]?.category == "Underwater")
        // An asset in a category the manifest doesn't list has none.
        #expect(byID[WallpaperFixtures.labelOnly]?.category == nil)
        // Nothing is located yet.
        #expect(aerials.allSatisfy { $0.videoURL == nil && $0.thumbnailURL == nil })
    }

    @Test func localizedNameWins() {
        let aerials = AerialCatalog.parse(entriesJSON: WallpaperFixtures.entriesJSON, localizedStrings: WallpaperFixtures.strings)
        let byID = Dictionary(uniqueKeysWithValues: aerials.map { ($0.id, $0) })
        #expect(byID[WallpaperFixtures.oregon]?.name == "Oregon Sunset")
        #expect(byID[WallpaperFixtures.jellies]?.name == "Alaskan Jellies Light")
        #expect(byID[WallpaperFixtures.tahoe]?.category == "Landscape")
        // A key missing from the strings falls back to the label.
        #expect(byID[WallpaperFixtures.labelOnly]?.name == "Fixture Label Only")
    }

    @Test func ordersByCategoryThenManifestOrder() {
        let aerials = AerialCatalog.parse(entriesJSON: WallpaperFixtures.entriesJSON, localizedStrings: WallpaperFixtures.strings)
        #expect(aerials.map(\.name) == ["Tahoe Day", "Oregon Sunset", "Alaskan Jellies Light", "Fixture Label Only"])
    }

    @Test func badManifestGivesNothing() {
        #expect(AerialCatalog.parse(entriesJSON: Data("not json".utf8), localizedStrings: [:]).isEmpty)
        #expect(AerialCatalog.parse(entriesJSON: Data(#"{"assets":[{"id":""}]}"#.utf8), localizedStrings: [:]).isEmpty)
        // A duplicated id is offered once.
        let twice = Data(#"{"assets":[{"id":"A","accessibilityLabel":"One"},{"id":"A","accessibilityLabel":"Two"}]}"#.utf8)
        #expect(AerialCatalog.parse(entriesJSON: twice, localizedStrings: [:]).map(\.name) == ["One"])
    }

    @Test func oneBadEntryDoesNotEmptyTheCatalog() {
        // Real manifests change between macOS releases: an odd field on one asset must cost that asset at most.
        let json = Data("""
        {
          "assets": [
            42,
            {"id": 7, "accessibilityLabel": "Numeric id"},
            {"accessibilityLabel": "No id at all"},
            {"id": "A", "accessibilityLabel": "Order as text", "preferredOrder": "first"},
            {"id": "B", "accessibilityLabel": "Fractional order", "preferredOrder": 0.5},
            {"id": "C", "accessibilityLabel": "Categories as text", "categories": "\(WallpaperFixtures.landscapes)"},
            {"id": "D", "accessibilityLabel": null, "localizedNameKey": 12, "shotID": "SHOT_D"},
            {"id": "E", "accessibilityLabel": "Fine", "categories": ["\(WallpaperFixtures.landscapes)"], "preferredOrder": 1}
          ],
          "categories": [
            {"id": "\(WallpaperFixtures.landscapes)", "localizedNameKey": "AerialCategoryLandscapes", "preferredOrder": "zero"},
            {"localizedNameKey": "NoID"},
            "garbage"
          ]
        }
        """.utf8)
        let aerials = AerialCatalog.parse(entriesJSON: json, localizedStrings: WallpaperFixtures.strings)
        #expect(Set(aerials.map(\.id)) == ["A", "B", "C", "D", "E"])
        let byID = Dictionary(uniqueKeysWithValues: aerials.map { ($0.id, $0) })
        #expect(byID["D"]?.name == "SHOT_D")
        #expect(byID["E"]?.category == "Landscape")
        #expect(byID["C"]?.category == nil)
        // Landscape (the only category) first; within it E; then the uncategorised by order: B (0.5), then A, C, D.
        #expect(aerials.map(\.id) == ["E", "B", "A", "C", "D"])
        // A manifest without an assets list is empty, not an error that takes anything else down.
        #expect(AerialCatalog.parse(entriesJSON: Data(#"{"categories": []}"#.utf8), localizedStrings: [:]).isEmpty)
        #expect(AerialCatalog.parse(entriesJSON: Data(#"{"assets": "nope"}"#.utf8), localizedStrings: [:]).isEmpty)
    }

    @Test func readsLocTablePreferringTheUsersLanguage() throws {
        let table = try WallpaperFixtures.locTable([
            "en": ["K": "Hello", "ONLY_EN": "English"],
            "en_GB": ["K": "Hello, mate"],
            "de": ["K": "Hallo"],
            "LocProvenance": "build 22L-1",
        ])
        let german = AerialCatalog.localizedStrings(locTable: table, preferredLanguages: ["de-DE", "en-US"])
        #expect(german["K"] == "Hallo")
        #expect(german["ONLY_EN"] == "English")   // missing keys fall back to English
        #expect(AerialCatalog.localizedStrings(locTable: table, preferredLanguages: ["en-GB"])["K"] == "Hello, mate")
        #expect(AerialCatalog.localizedStrings(locTable: table, preferredLanguages: ["fr-FR"])["K"] == "Hello")
        #expect(AerialCatalog.localizedStrings(locTable: Data("junk".utf8), preferredLanguages: ["en"]).isEmpty)
    }

    @Test func readsStringsBundleInEitherLayout() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // macOS 26: one loctable in Contents/Resources.
        let modern = dir.appending(path: "Modern.bundle", directoryHint: .isDirectory)
        let resources = modern.appending(path: "Contents/Resources", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try WallpaperFixtures.locTable(["en": ["K": "Hello"]]).write(to: resources.appending(path: "Localizable.nocache.loctable"))
        #expect(AerialCatalog.localizedStrings(bundle: modern, preferredLanguages: ["en-US"])["K"] == "Hello")
        // Older systems: <lang>.lproj/Localizable.nocache.strings (a property list).
        let legacy = dir.appending(path: "Legacy.bundle", directoryHint: .isDirectory)
        for (lang, text) in [("en", "Hello"), ("de", "Hallo")] {
            let lproj = legacy.appending(path: "Contents/Resources/\(lang).lproj", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: ["K": text], format: .binary, options: 0)
            try data.write(to: lproj.appending(path: "Localizable.nocache.strings"))
        }
        #expect(AerialCatalog.localizedStrings(bundle: legacy, preferredLanguages: ["de"])["K"] == "Hallo")
        #expect(AerialCatalog.localizedStrings(bundle: dir.appending(path: "Missing.bundle"), preferredLanguages: ["en"]).isEmpty)
    }

    @Test func locationsCoverBothLayouts() {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        let locations = AerialCatalog.locations(home: home)
        #expect(locations.count == 2)
        let modern = locations[0]
        #expect(modern.manifest.path == "/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/manifest/entries.json")
        #expect(modern.strings.path == "/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/manifest/TVIdleScreenStrings.bundle")
        #expect(modern.videoFolders.map(\.path) == ["/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/videos"])
        #expect(modern.thumbnails?.path == "/Users/someone/Library/Application Support/com.apple.wallpaper/aerials/thumbnails")
        let legacy = locations[1]
        #expect(legacy.manifest.path == "/Library/Application Support/com.apple.idleassetsd/Customer/entries.json")
        #expect(legacy.videoFolders.first?.path == "/Library/Application Support/com.apple.idleassetsd/Customer/4KSDR240FPS")
        #expect(AerialCatalog.locations.first?.manifest.path.hasSuffix("com.apple.wallpaper/aerials/manifest/entries.json") == true)
    }

    @Test func onlyDownloadedAerialsOffered() throws {
        let home = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: home) }
        // Tahoe is downloaded with a thumbnail; Oregon's file is empty (an interrupted download); Jellies only has a
        // thumbnail; the label-only aerial has nothing.
        let root = try WallpaperFixtures.aerialsFolder(in: home, videos: [WallpaperFixtures.tahoe: 2048, WallpaperFixtures.oregon: 0],
                                                       thumbnails: [WallpaperFixtures.tahoe, WallpaperFixtures.jellies])
        let aerials = AerialCatalog.load(locations: [AerialCatalog.locations(home: home)[0]], preferredLanguages: ["en"])
        #expect(aerials.map(\.id) == [WallpaperFixtures.tahoe])
        let tahoe = try #require(aerials.first)
        #expect(tahoe.name == "Tahoe Day")
        #expect(tahoe.category == "Landscape")
        #expect(tahoe.videoURL?.path == root.appending(path: "videos/\(WallpaperFixtures.tahoe).mov").path)
        #expect(tahoe.thumbnailURL?.path == root.appending(path: "thumbnails/\(WallpaperFixtures.tahoe).png").path)
        // No manifest at all (aerials never opened in System Settings): nothing, and no crash.
        #expect(AerialCatalog.load(locations: [AerialCatalog.locations(home: home.appending(path: "nobody"))[0]], preferredLanguages: ["en"]).isEmpty)
    }
}

// MARK: - Sources and assignments

@Suite struct WallpaperAssignmentsTests {
    let main = DisplayRef(key: "3E97987E-7C30-4857-BC7F-26602716A7CC", name: "P27u-20 (1)")
    let side = DisplayRef(key: "6F400F72-AF91-42ED-9EB4-33FFE02D5F89", name: "P27u-20 (2)")

    @Test func assignmentsRoundTrip() throws {
        var assignments = WallpaperAssignments()
        #expect(assignments.isEmpty)
        assignments.assign(.aerial(id: WallpaperFixtures.tahoe), to: main)
        assignments.assign(.video(path: "/Users/kevo/Movies/Rain on glass.mov", bookmark: Data([1, 2, 3])), to: side)
        let data = try JSONEncoder().encode(assignments)
        let decoded = try JSONDecoder().decode(WallpaperAssignments.self, from: data)
        #expect(decoded == assignments)
        #expect(decoded[main.key] == WallpaperAssignment(source: .aerial(id: WallpaperFixtures.tahoe), displayName: "P27u-20 (1)"))
        #expect(decoded[side.key]?.source == .video(path: "/Users/kevo/Movies/Rain on glass.mov", bookmark: Data([1, 2, 3])))
        #expect(decoded["unknown"] == nil)
        // Reassigning replaces; removing forgets.
        assignments.assign(.aerial(id: WallpaperFixtures.oregon), to: main)
        #expect(assignments[main.key]?.source == .aerial(id: WallpaperFixtures.oregon))
        #expect(assignments.remove(side.key)?.displayName == "P27u-20 (2)")
        #expect(assignments.remove(side.key) == nil)
        #expect(assignments.keys == [main.key])
    }

    @Test func sourceIdentityIgnoresTheBookmark() {
        let a = WallpaperSource.video(path: "/m/Rain.mov", bookmark: Data([1]))
        let b = WallpaperSource.video(path: "/m/Rain.mov", bookmark: nil)
        #expect(a.identity == b.identity)
        #expect(a.identity != WallpaperSource.aerial(id: "/m/Rain.mov").identity)
        #expect(a.videoFileName == "Rain.mov")
        #expect(WallpaperSource.aerial(id: "X").videoFileName == nil)
        #expect(WallpaperSource.aerial(id: "X").aerialID == "X")
        #expect(a.aerialID == nil)
    }

    @Test func adoptsAssignmentWhenDisplayKeyChanges() {
        var assignments = WallpaperAssignments()
        assignments.assign(.aerial(id: WallpaperFixtures.tahoe), to: DisplayRef(key: "OLD-KEY", name: "Q27G4ZD"))
        let moved = assignments.adopt([DisplayRef(key: "NEW-KEY", name: "Q27G4ZD"), main])
        #expect(moved == [WallpaperAssignments.Move(from: "OLD-KEY", to: "NEW-KEY")])
        #expect(assignments["NEW-KEY"]?.source == .aerial(id: WallpaperFixtures.tahoe))
        #expect(assignments["OLD-KEY"] == nil)
        // A second pass finds nothing to do.
        #expect(assignments.adopt([DisplayRef(key: "NEW-KEY", name: "Q27G4ZD")]).isEmpty)
    }

    @Test func adoptNeverStealsAnotherDisplaysWallpaper() {
        var assignments = WallpaperAssignments()
        assignments.assign(.aerial(id: WallpaperFixtures.tahoe), to: main)
        // A new display that happens to share the name of a connected one gets nothing.
        let twin = DisplayRef(key: "TWIN", name: main.name)
        #expect(assignments.adopt([main, twin]).isEmpty)
        #expect(assignments[twin.key] == nil)
        // A display that already has its own wallpaper keeps it.
        assignments.assign(.aerial(id: WallpaperFixtures.jellies), to: DisplayRef(key: "GONE", name: side.name))
        assignments.assign(.aerial(id: WallpaperFixtures.oregon), to: side)
        #expect(assignments.adopt([side]).isEmpty)
        #expect(assignments[side.key]?.source == .aerial(id: WallpaperFixtures.oregon))
        // Two forgotten keys under one name: one display adopts exactly one of them.
        var twins = WallpaperAssignments()
        twins.assign(.aerial(id: "A"), to: DisplayRef(key: "K1", name: "Twin"))
        twins.assign(.aerial(id: "B"), to: DisplayRef(key: "K2", name: "Twin"))
        #expect(twins.adopt([DisplayRef(key: "K3", name: "Twin")]) == [WallpaperAssignments.Move(from: "K1", to: "K3")])
        #expect(twins.keys == ["K2", "K3"])
    }

    @Test func listsVideosAssignedAnywhere() {
        var assignments = WallpaperAssignments()
        assignments.assign(.video(path: "/m/b.mov", bookmark: nil), to: main)
        assignments.assign(.video(path: "/m/a.mov", bookmark: nil), to: side)
        assignments.assign(.video(path: "/m/b.mov", bookmark: Data([9])), to: DisplayRef(key: "K", name: "K272HUL"))
        assignments.assign(.aerial(id: WallpaperFixtures.tahoe), to: DisplayRef(key: "Q", name: "Q27G4ZD"))
        #expect(assignments.videos.map(\.identity) == ["video:/m/a.mov", "video:/m/b.mov"])
    }
}

// MARK: - Same on all displays

@Suite struct WallpaperSyncTests {
    let left = DisplayRef(key: "L", name: "K272HUL")
    let main = DisplayRef(key: "M", name: "P27u-20 (1)")
    let right = DisplayRef(key: "R", name: "Q27G4ZD")
    let tahoe = WallpaperSource.aerial(id: WallpaperFixtures.tahoe)
    let oregon = WallpaperSource.aerial(id: WallpaperFixtures.oregon)

    /// The panel's order: left to right.
    var screens: [DisplayRef] { [left, main, right] }

    private func assignments(_ pairs: [(DisplayRef, WallpaperSource)]) -> WallpaperAssignments {
        var result = WallpaperAssignments()
        for (display, source) in pairs { result.assign(source, to: display) }
        return result
    }

    @Test func theMainDisplaysWallpaperWins() {
        let all = assignments([(left, oregon), (main, tahoe)])
        #expect(WallpaperSync.source(screens: screens, mainKey: main.key, assignments: all) == tahoe)
        // The others come into line, in the panel's order; the main display needs nothing.
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: all)
                == WallpaperSync.Plan(source: tahoe, displays: [left, right]))
    }

    @Test func fallsBackToTheFirstDisplayThatHasOne() {
        // The main display has none: the first assigned display in panel order is the source, not the lowest key.
        let all = assignments([(right, oregon), (left, tahoe)])
        #expect(WallpaperSync.source(screens: screens, mainKey: main.key, assignments: all) == tahoe)
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: all)
                == WallpaperSync.Plan(source: tahoe, displays: [main, right]))
        // No known main display behaves the same.
        #expect(WallpaperSync.source(screens: screens, mainKey: nil, assignments: all) == tahoe)
        #expect(WallpaperSync.source(screens: screens, mainKey: "not connected", assignments: all) == tahoe)
    }

    @Test func nothingToSyncWhenNoDisplayHasOne() {
        let empty = WallpaperAssignments()
        #expect(WallpaperSync.source(screens: screens, mainKey: main.key, assignments: empty) == nil)
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: empty) == nil)
        #expect(WallpaperSync.plan(screens: [], mainKey: nil, assignments: assignments([(main, tahoe)])) == nil)
    }

    /// Assignments don't tell "None" from "not set" (None removes the entry), so a main display without a
    /// wallpaper never makes the others lose theirs: choosing None while synced clears every display at once
    /// (`WallpaperModel.assign`), and a lone leftover wallpaper is the one the rest take.
    @Test func aMainDisplayWithoutAWallpaperDoesNotSyncToNone() {
        let all = assignments([(right, oregon)])
        #expect(WallpaperSync.source(screens: screens, mainKey: main.key, assignments: all) == oregon)
    }

    @Test func nothingToChangeWhenTheyAlreadyMatch() {
        let all = assignments([(left, tahoe), (main, tahoe), (right, tahoe)])
        #expect(WallpaperSync.source(screens: screens, mainKey: main.key, assignments: all) == tahoe)
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: all) == nil)
        // The same video with a different bookmark is the same wallpaper.
        let rain = WallpaperSource.video(path: "/m/Rain.mov", bookmark: Data([1]))
        let sameRain = assignments([(left, .video(path: "/m/Rain.mov", bookmark: Data([2]))), (main, rain),
                                    (right, .video(path: "/m/Rain.mov", bookmark: nil))])
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: sameRain) == nil)
    }

    @Test func aNewDisplayJoinsTheSyncedWallpaper() {
        let all = assignments([(left, tahoe), (main, tahoe)])
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: all)
                == WallpaperSync.Plan(source: tahoe, displays: [right]))
    }

    /// At launch and on hot-plug Orbit only fills displays that have no wallpaper: a display that already shows
    /// a different one keeps it, so an upgrade (or a relaunch) never overwrites per-display choices for good.
    @Test func fillingLeavesDisplaysThatHaveAWallpaper() {
        let all = assignments([(left, oregon), (main, tahoe)])
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: all, replacing: false)
                == WallpaperSync.Plan(source: tahoe, displays: [right]))
        var filled = all
        let changed = filled.syncDisplays(screens: screens, mainKey: main.key, replacing: false)
        #expect(changed)
        #expect(filled[left.key]?.source == oregon)
        #expect(filled[right.key]?.source == tahoe)
        // Every display has one already: nothing to fill, even though they differ.
        let full = assignments([(left, oregon), (main, tahoe), (right, oregon)])
        #expect(WallpaperSync.plan(screens: screens, mainKey: main.key, assignments: full, replacing: false) == nil)
    }

    @Test func unpluggedDisplaysAreLeftAlone() {
        // The unplugged "R" keeps its wallpaper, and does not count as the first display that has one.
        let all = assignments([(right, oregon)])
        #expect(WallpaperSync.plan(screens: [left, main], mainKey: main.key, assignments: all) == nil)
        let mixed = assignments([(right, oregon), (main, tahoe)])
        #expect(WallpaperSync.plan(screens: [left, main], mainKey: main.key, assignments: mixed)
                == WallpaperSync.Plan(source: tahoe, displays: [left]))
    }

    @Test func syncingAssignmentsKeepsTheSourceAndEachDisplaysName() {
        var all = assignments([(main, .video(path: "/m/Rain.mov", bookmark: Data([5]))), (left, oregon)])
        all.assign(oregon, to: DisplayRef(key: "GONE", name: "Unplugged"))
        let changed = all.syncDisplays(screens: screens, mainKey: main.key)
        #expect(changed)
        for display in screens {
            #expect(all[display.key] == WallpaperAssignment(source: .video(path: "/m/Rain.mov", bookmark: Data([5])),
                                                           displayName: display.name))
        }
        #expect(all["GONE"]?.source == oregon)
        // Already in line: nothing changes.
        let before = all
        let changedAgain = all.syncDisplays(screens: screens, mainKey: main.key)
        #expect(changedAgain == false)
        #expect(all == before)
        // Nothing assigned: nothing to do.
        var empty = WallpaperAssignments()
        let changedEmpty = empty.syncDisplays(screens: screens, mainKey: main.key)
        #expect(changedEmpty == false)
        #expect(empty.isEmpty)
    }
}

// MARK: - When wallpapers play, and which displays get a window

@Suite struct WallpaperPausePolicyTests {
    /// A display in plain use: visible, unlocked, awake, on AC, default preferences.
    let normal = DisplayConditions()

    @Test func playsOtherwise() {
        #expect(normal.pauseOnBattery == false)
        #expect(normal.pauseInLowPower == true)
        #expect(WallpaperPausePolicy.state(for: normal) == .playing)
        #expect(WallpaperPausePolicy.state(for: normal).isPlaying)
        // Preferences alone never pause: only the conditions they guard.
        #expect(WallpaperPausePolicy.state(for: DisplayConditions(pauseOnBattery: true, pauseInLowPower: true)) == .playing)
    }

    @Test func pauseWhenCovered() {
        var c = normal
        c.screenCovered = true
        #expect(WallpaperPausePolicy.state(for: c) == .paused(.screenCovered))
        #expect(!WallpaperPausePolicy.state(for: c).isPlaying)
    }

    @Test func pauseWhenLocked() {
        var c = normal
        c.screenLocked = true
        #expect(WallpaperPausePolicy.state(for: c) == .paused(.screenLocked))
    }

    @Test func pauseWhenAsleep() {
        var c = normal
        c.displayAsleep = true
        #expect(WallpaperPausePolicy.state(for: c) == .paused(.displayAsleep))
    }

    @Test func pauseOnBatteryOnlyIfEnabled() {
        var c = normal
        c.onBattery = true
        #expect(WallpaperPausePolicy.state(for: c) == .playing)
        c.pauseOnBattery = true
        #expect(WallpaperPausePolicy.state(for: c) == .paused(.onBattery))
        c.onBattery = false
        #expect(WallpaperPausePolicy.state(for: c) == .playing)
    }

    @Test func pauseInLowPower() {
        var c = normal
        c.lowPowerMode = true
        #expect(WallpaperPausePolicy.state(for: c) == .paused(.lowPowerMode))
        c.pauseInLowPower = false
        #expect(WallpaperPausePolicy.state(for: c) == .playing)
    }

    @Test func strongestReasonIsReported() {
        let all = DisplayConditions(screenCovered: true, screenLocked: true, displayAsleep: true, onBattery: true,
                                    lowPowerMode: true, pauseOnBattery: true, pauseInLowPower: true)
        #expect(WallpaperPausePolicy.state(for: all) == .paused(.displayAsleep))
        #expect(WallpaperPausePolicy.state(for: DisplayConditions(screenCovered: true, screenLocked: true)) == .paused(.screenLocked))
        #expect(WallpaperPausePolicy.state(for: DisplayConditions(screenCovered: true, onBattery: true, lowPowerMode: true,
                                                                  pauseOnBattery: true)) == .paused(.screenCovered))
        #expect(PauseReason.allCases.allSatisfy { !$0.label.isEmpty })
    }

    @Test func unseenWindowCountsAsCoveredAfterTheGracePeriod() {
        let grace = WallpaperVisibility.grace
        #expect(grace > 0 && grace <= 10)
        // Visible now: never covered.
        #expect(!WallpaperVisibility.isCovered(visibleNow: true, everVisible: false, secondsSinceShown: 0))
        #expect(!WallpaperVisibility.isCovered(visibleNow: true, everVisible: true, secondsSinceShown: 999))
        // Seen before, hidden now: covered at once.
        #expect(WallpaperVisibility.isCovered(visibleNow: false, everVisible: true, secondsSinceShown: 0.1))
        // Never reported visible: plays while macOS may still be catching up, then counts as covered (no decoding
        // for a window nobody can see, e.g. one drawn under the system wallpaper).
        #expect(!WallpaperVisibility.isCovered(visibleNow: false, everVisible: false, secondsSinceShown: grace - 0.5))
        #expect(WallpaperVisibility.isCovered(visibleNow: false, everVisible: false, secondsSinceShown: grace))
        #expect(WallpaperVisibility.isCovered(visibleNow: false, everVisible: false, secondsSinceShown: 3600))
        // A window not shown yet is not covered.
        #expect(!WallpaperVisibility.isCovered(visibleNow: false, everVisible: false, secondsSinceShown: nil))
        let covered = DisplayConditions(screenCovered: WallpaperVisibility.isCovered(visibleNow: false, everVisible: false,
                                                                                     secondsSinceShown: grace + 1))
        #expect(WallpaperPausePolicy.state(for: covered) == .paused(.screenCovered))
    }

    @Test func sharedPlayerPlaysWhileAnyDisplayPlays() {
        #expect(PlaybackState.combined([.paused(.screenCovered), .playing]) == .playing)
        #expect(PlaybackState.combined([.paused(.screenCovered), .paused(.screenLocked)]) == .paused(.screenLocked))
        #expect(PlaybackState.combined([.paused(.onBattery)]) == .paused(.onBattery))
    }

    // The window plan: one window per connected display that has a playable wallpaper.

    let a = DisplayRef(key: "A", name: "P27u-20 (1)")
    let b = DisplayRef(key: "B", name: "P27u-20 (2)")
    let c = DisplayRef(key: "C", name: "Q27G4ZD")

    private func assignments(_ pairs: [(DisplayRef, WallpaperSource)]) -> WallpaperAssignments {
        var result = WallpaperAssignments()
        for (display, source) in pairs { result.assign(source, to: display) }
        return result
    }

    @Test func windowForRemovedDisplayCloses() {
        let saved = assignments([(a, .aerial(id: "T")), (b, .aerial(id: "O"))])
        let before = WallpaperPlan.desired(screens: [a, b], assignments: saved) { _ in true }
        #expect(before == ["A": .aerial(id: "T"), "B": .aerial(id: "O")])
        // B is unplugged: its window closes; A's is untouched; B keeps its assignment for when it returns.
        let after = WallpaperPlan.desired(screens: [a], assignments: saved) { _ in true }
        #expect(WallpaperPlan.changes(from: before, to: after) == WallpaperPlan.Changes(close: ["B"], open: [], change: []))
        #expect(saved["B"] != nil)
        // Plugging it back in reopens it.
        #expect(WallpaperPlan.changes(from: after, to: before) == WallpaperPlan.Changes(close: [], open: ["B"], change: []))
    }

    @Test func onlyAssignedConnectedDisplaysWithPlayableSourcesGetWindows() {
        let gone = DisplayRef(key: "GONE", name: "K272HUL")
        let saved = assignments([(a, .aerial(id: "T")), (b, .aerial(id: "DELETED")), (gone, .aerial(id: "O"))])
        let desired = WallpaperPlan.desired(screens: [a, b, c], assignments: saved) { $0 != .aerial(id: "DELETED") }
        #expect(desired == ["A": .aerial(id: "T")])
        #expect(WallpaperPlan.desired(screens: [a, b, c], assignments: WallpaperAssignments()) { _ in true }.isEmpty)
    }

    @Test func changedSourceSwapsInPlace() {
        let current: [String: WallpaperSource] = ["A": .aerial(id: "T"), "B": .video(path: "/m/r.mov", bookmark: nil)]
        // A new bookmark for the same file is not a change; a different aerial is.
        let desired: [String: WallpaperSource] = ["A": .aerial(id: "O"), "B": .video(path: "/m/r.mov", bookmark: Data([1])),
                                                   "C": .aerial(id: "T")]
        #expect(WallpaperPlan.changes(from: current, to: desired) == WallpaperPlan.Changes(close: [], open: ["C"], change: ["A"]))
        #expect(WallpaperPlan.changes(from: current, to: current).isEmpty)
        #expect(WallpaperPlan.changes(from: current, to: [:]) == WallpaperPlan.Changes(close: ["A", "B"], open: [], change: []))
    }
}

// MARK: - Settings, the desktop picture ledger and still frames

@Suite struct WallpaperSettingsTests {
    let stills = URL(fileURLWithPath: "/Users/kevo/Library/Application Support/Orbit/Wallpaper/stills", isDirectory: true)
    let mountains = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mountains.heic")
    let photo = URL(fileURLWithPath: "/Users/kevo/Pictures/Beach.jpg")

    private func orbitStill(_ name: String = "aerial-X.png") -> URL { stills.appending(path: name) }

    /// Kevo's own picture with "Fit to Screen" and a dark fill colour, as NSWorkspace reports it.
    let mountainsPicture = DesktopPicture(url: URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mountains.heic"),
                                          options: DesktopPictureOptions(imageScaling: 3, allowClipping: false,
                                                                         fillColor: [0.1, 0.1, 0.12, 1]))
    let photoPicture = DesktopPicture(url: URL(fileURLWithPath: "/Users/kevo/Pictures/Beach.jpg"), options: nil)

    @Test func settingsRoundTrip() throws {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let fresh = WallpaperSettings(defaults: defaults)
        #expect(fresh.assignments.isEmpty)
        #expect(fresh.pauseOnBattery == false)
        #expect(fresh.pauseInLowPower == true)
        #expect(fresh.setStillFrame == true)
        #expect(fresh.syncDisplays == true)
        #expect(fresh.desktopPictures.isEmpty)

        fresh.assignments.assign(.aerial(id: WallpaperFixtures.tahoe), to: DisplayRef(key: "A", name: "P27u-20 (1)"))
        fresh.assignments.assign(.video(path: "/m/Rain.mov", bookmark: Data([7])), to: DisplayRef(key: "B", name: "K272HUL"))
        fresh.pauseOnBattery = true
        fresh.pauseInLowPower = false
        fresh.setStillFrame = false
        fresh.syncDisplays = false
        fresh.desktopPictures.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        fresh.desktopPictures.requestRestore("A")

        let reread = WallpaperSettings(defaults: defaults)
        #expect(reread.assignments == fresh.assignments)
        #expect(reread.pauseOnBattery == true)
        #expect(reread.pauseInLowPower == false)
        #expect(reread.setStillFrame == false)
        #expect(reread.syncDisplays == false)
        #expect(reread.desktopPictures == fresh.desktopPictures)
        #expect(reread.desktopPictures["A"]?.original == mountainsPicture)
        #expect(reread.desktopPictures["A"]?.restorePending == true)
        // Every key is the feature's own.
        let keys = defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("wallpaper.") }
        #expect(Set(keys) == ["wallpaper.assignments", "wallpaper.pauseOnBattery", "wallpaper.pauseInLowPower",
                              "wallpaper.setStillFrame", "wallpaper.syncDisplays", "wallpaper.desktopPictures"])
        // Unreadable data falls back to none rather than crashing.
        defaults.set(Data("garbage".utf8), forKey: "wallpaper.assignments")
        defaults.set(Data("garbage".utf8), forKey: "wallpaper.desktopPictures")
        #expect(WallpaperSettings(defaults: defaults).assignments.isEmpty)
        #expect(WallpaperSettings(defaults: defaults).desktopPictures.isEmpty)
    }

    @Test func migratesTheFirstBuildsPictureList() {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        defaults.set(["A": mountains.absoluteString], forKey: "wallpaper.previousDesktopPictures")
        let settings = WallpaperSettings(defaults: defaults)
        #expect(settings.desktopPictures["A"]?.original == DesktopPicture(url: mountains, options: nil))
        #expect(settings.desktopPictures["A"]?.restorePending == false)
    }

    @Test func remembersTheUsersPictureBeforeTheFirstStill() {
        var ledger = DesktopPictureLedger()
        ledger.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        // While the display keeps a wallpaper, later stills never overwrite the original (another Space may show
        // the user's own picture only because it never got a still).
        ledger.willSetStill("aerial-Y.png", on: "A", current: photoPicture, stillsFolder: stills)
        ledger.willSetStill("aerial-Y.png", on: "A", current: DesktopPicture(url: orbitStill("aerial-X.png"), options: nil),
                            stillsFolder: stills)
        #expect(ledger["A"]?.original == mountainsPicture)
        #expect(ledger["A"]?.stills == ["aerial-X.png", "aerial-Y.png"])
        #expect(ledger["A"]?.restorePending == false)
        // Orbit's own still is never remembered as "the user's picture", nor is nothing.
        ledger.willSetStill("aerial-X.png", on: "B", current: DesktopPicture(url: orbitStill(), options: nil), stillsFolder: stills)
        ledger.willSetStill("aerial-X.png", on: "C", current: nil, stillsFolder: stills)
        #expect(ledger["B"]?.original == nil)
        #expect(ledger["C"]?.original == nil)
        // The still list stays short.
        for index in 0..<20 { ledger.willSetStill("video-\(index).png", on: "A", current: nil, stillsFolder: stills) }
        #expect(ledger["A"]?.stills.count == DesktopPictureLedger.stillHistory)
        #expect(ledger["A"]?.stills.last == "video-19.png")
    }

    @Test func restoreAttemptedWhileAnotherSpaceIsCurrent() {
        // Space 1 got Orbit's still at launch; Kevo picks None (or quits) while on Space 2, which shows his photo.
        var ledger = DesktopPictureLedger()
        ledger.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        ledger.requestRestore("A")
        #expect(ledger.restoreAction(for: "A", current: photo, stillsFolder: stills) == .leave)
        // Nothing is forgotten: the saved picture waits, and so do the stills it protects.
        #expect(ledger["A"]?.original == mountainsPicture)
        #expect(ledger["A"]?.restorePending == true)
        #expect(ledger.pendingKeys == ["A"])
        #expect(ledger.protectedStills == ["aerial-X.png"])
        // Back on Space 1 (still Orbit's still): the original goes back with its own scaling and fill colour.
        #expect(ledger.restoreAction(for: "A", current: orbitStill("aerial-X.png"), stillsFolder: stills) == .restore(mountainsPicture))
        // A third Space may show the still too: the entry stays pending for it.
        #expect(ledger.restoreAction(for: "A", current: orbitStill("aerial-X.png"), stillsFolder: stills) == .restore(mountainsPicture))
        // A display that never had a still, or one not waiting for a restore, is left alone.
        #expect(ledger.restoreAction(for: "Z", current: orbitStill(), stillsFolder: stills) == .leave)
        var active = DesktopPictureLedger()
        active.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        #expect(active.restoreAction(for: "A", current: orbitStill("aerial-X.png"), stillsFolder: stills) == .leave)
        // Without a remembered picture there is nothing to put back.
        var unknown = DesktopPictureLedger()
        unknown.willSetStill("aerial-X.png", on: "A", current: nil, stillsFolder: stills)
        unknown.requestRestore("A")
        #expect(unknown.restoreAction(for: "A", current: orbitStill("aerial-X.png"), stillsFolder: stills) == .leave)
    }

    @Test func aNewWallpaperAfterARestoreRemembersTheCurrentPicture() {
        var ledger = DesktopPictureLedger()
        ledger.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        ledger.requestRestore("A")
        // Kevo chose a photo for that display meanwhile, then gives it a wallpaper again: the photo is what comes back.
        ledger.willSetStill("aerial-Y.png", on: "A", current: photoPicture, stillsFolder: stills)
        #expect(ledger["A"]?.original == photoPicture)
        #expect(ledger["A"]?.restorePending == false)
        // Still pending but the current Space shows Orbit's still: the original stays.
        ledger.requestRestore("A")
        ledger.willSetStill("aerial-Z.png", on: "A", current: DesktopPicture(url: orbitStill("aerial-Y.png"), options: nil),
                            stillsFolder: stills)
        #expect(ledger["A"]?.original == photoPicture)
    }

    @Test func stillWaitingForRestoreIsNeverDeleted() {
        var ledger = DesktopPictureLedger()
        ledger.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        ledger.willSetStill("aerial-Y.png", on: "A", current: nil, stillsFolder: stills)
        ledger.willSetStill("aerial-Z.png", on: "B", current: photoPicture, stillsFolder: stills)
        ledger.requestRestore("A")
        let files = ["aerial-W.png", "aerial-X.png", "aerial-Y.png", "aerial-Z.png", "notes.txt"]
        // A's stills may still be some Space's picture until its original is back: kept. B's still is kept only
        // because a saved wallpaper uses it.
        #expect(StillFrame.removable(files, keeping: ["aerial-Z.png"], ledger: ledger) == ["aerial-W.png"])
        #expect(StillFrame.removable(files, keeping: [], ledger: ledger) == ["aerial-W.png", "aerial-Z.png"])
        // Once A has a wallpaper again, its old stills are fair game.
        ledger.willSetStill("aerial-Q.png", on: "A", current: nil, stillsFolder: stills)
        #expect(StillFrame.removable(files, keeping: ["aerial-Z.png"], ledger: ledger) == ["aerial-W.png", "aerial-X.png", "aerial-Y.png"])
    }

    @Test func stopMarksEveryDisplayAndKeysCanMove() {
        var ledger = DesktopPictureLedger()
        ledger.willSetStill("aerial-X.png", on: "A", current: mountainsPicture, stillsFolder: stills)
        ledger.willSetStill("aerial-Y.png", on: "B", current: photoPicture, stillsFolder: stills)
        ledger.requestRestoreAll()
        #expect(ledger.pendingKeys == ["A", "B"])
        ledger.requestRestore("nobody")
        #expect(ledger["nobody"] == nil)
        ledger.move(from: "B", to: "B2")
        #expect(ledger["B"] == nil)
        #expect(ledger["B2"]?.original == photoPicture)
        // Never onto a display that has its own entry.
        ledger.move(from: "A", to: "B2")
        #expect(ledger["A"]?.original == mountainsPicture)
        #expect(ledger["B2"]?.original == photoPicture)
    }

    @Test func replacesOnlyStaleStillsOnSpaceChange() {
        #expect(DesktopPictureLedger.shouldReplaceStill(current: orbitStill("aerial-old.png"), with: "aerial-new.png", stillsFolder: stills))
        #expect(!DesktopPictureLedger.shouldReplaceStill(current: orbitStill("aerial-new.png"), with: "aerial-new.png", stillsFolder: stills))
        // A Space showing the user's own picture keeps it.
        #expect(!DesktopPictureLedger.shouldReplaceStill(current: photo, with: "aerial-new.png", stillsFolder: stills))
        #expect(!DesktopPictureLedger.shouldReplaceStill(current: nil, with: "aerial-new.png", stillsFolder: stills))
    }

    @Test func stillFrameNames() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(StillFrame.fileName(for: .aerial(id: WallpaperFixtures.tahoe), modified: nil)
                == "aerial-\(WallpaperFixtures.tahoe).png")
        #expect(StillFrame.fileName(for: .aerial(id: "../../evil"), modified: nil) == "aerial-evil.png")
        let video = StillFrame.fileName(for: .video(path: "/m/Rain.mov", bookmark: nil), modified: date)
        #expect(video.hasPrefix("video-") && video.hasSuffix(".png"))
        // Stable for the same file and date (bookmark ignored); new when the file changes or moves.
        #expect(StillFrame.fileName(for: .video(path: "/m/Rain.mov", bookmark: Data([1])), modified: date) == video)
        #expect(StillFrame.fileName(for: .video(path: "/m/Rain.mov", bookmark: nil), modified: date.addingTimeInterval(1)) != video)
        #expect(StillFrame.fileName(for: .video(path: "/m/Snow.mov", bookmark: nil), modified: date) != video)
    }

    @Test func recognisesOrbitsOwnStills() {
        #expect(StillFrame.isStill(orbitStill(), in: stills))
        #expect(!StillFrame.isStill(photo, in: stills))
        #expect(!StillFrame.isStill(URL(fileURLWithPath: stills.path + "-old/aerial-X.png"), in: stills))
        #expect(!StillFrame.isStill(URL(string: "https://example.invalid/aerial-X.png")!, in: stills))
        // Cleanup only ever considers Orbit's own still names.
        let files = ["aerial-A.png", "aerial-B.png", "video-0123.png", "notes.txt", "Beach.jpg", "aerial-C.heic"]
        #expect(StillFrame.unused(files, keeping: ["aerial-B.png"]) == ["aerial-A.png", "video-0123.png"])
    }
}
