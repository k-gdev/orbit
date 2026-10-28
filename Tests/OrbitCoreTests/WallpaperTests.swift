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
