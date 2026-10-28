import Foundation

/// One of Apple's aerial videos, as listed in the system's aerial manifest.
public struct Aerial: Identifiable, Hashable, Sendable {
    /// The manifest's asset id (also the video's and thumbnail's file name).
    public let id: String
    /// The localized name (`localizedNameKey` looked up in `TVIdleScreenStrings`), else `accessibilityLabel`,
    /// else the shot id.
    public let name: String
    /// The localized name of the asset's first category ("Landscape", "Underwater"), or nil when the manifest
    /// doesn't list that category.
    public let category: String?
    /// The downloaded video. Nil straight out of `AerialCatalog.parse`; `AerialCatalog.load` only returns
    /// aerials that have one.
    public var videoURL: URL?
    /// The manifest folder's thumbnail (`thumbnails/<id>.png`), when present.
    public var thumbnailURL: URL?

    public init(id: String, name: String, category: String?, videoURL: URL? = nil, thumbnailURL: URL? = nil) {
        self.id = id
        self.name = name
        self.category = category
        self.videoURL = videoURL
        self.thumbnailURL = thumbnailURL
    }
}

/// Where one macOS version keeps its aerials. Orbit only reads these folders: it never downloads an aerial and
/// never writes here.
public struct AerialLocation: Equatable, Sendable {
    /// `entries.json`.
    public let manifest: URL
    /// `TVIdleScreenStrings.bundle` (localized names).
    public let strings: URL
    /// Folders that may hold `<id>.mov`, best first.
    public let videoFolders: [URL]
    /// The folder of `<id>.png` thumbnails, when the layout has one.
    public let thumbnails: URL?

    public init(manifest: URL, strings: URL, videoFolders: [URL], thumbnails: URL?) {
        self.manifest = manifest
        self.strings = strings
        self.videoFolders = videoFolders
        self.thumbnails = thumbnails
    }
}

/// Reads the aerial manifest the system keeps for the Wallpaper and Screen Saver settings, and offers the aerials
/// whose videos are already on this Mac.
public enum AerialCatalog {
    /// The known layouts, newest first: macOS 26's per-user `~/Library/Application Support/com.apple.wallpaper/aerials/`
    /// (`manifest/entries.json`, `videos/<id>.mov`, `thumbnails/<id>.png`), then macOS 14/15's
    /// `/Library/Application Support/com.apple.idleassetsd/Customer/`.
    public static var locations: [AerialLocation] {
        locations(home: FileManager.default.homeDirectoryForCurrentUser)
    }

    /// `locations` for a given home folder (tests point it at a temp folder).
    public static func locations(home: URL) -> [AerialLocation] {
        let modern = home.appending(path: "Library/Application Support/com.apple.wallpaper/aerials", directoryHint: .isDirectory)
        let legacy = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer", isDirectory: true)
        return [
            AerialLocation(manifest: modern.appending(path: "manifest/entries.json", directoryHint: .notDirectory),
                           strings: modern.appending(path: "manifest/TVIdleScreenStrings.bundle", directoryHint: .isDirectory),
                           videoFolders: [modern.appending(path: "videos", directoryHint: .isDirectory)],
                           thumbnails: modern.appending(path: "thumbnails", directoryHint: .isDirectory)),
            AerialLocation(manifest: legacy.appending(path: "entries.json", directoryHint: .notDirectory),
                           strings: legacy.appending(path: "TVIdleScreenStrings.bundle", directoryHint: .isDirectory),
                           videoFolders: legacyVideoFolders.map { legacy.appending(path: $0, directoryHint: .isDirectory) },
                           thumbnails: nil),
        ]
    }

    /// The per-format folders macOS 14/15 downloads into, best first.
    private static let legacyVideoFolders = ["4KSDR240FPS", "4KSDR", "2KSDR240FPS", "2KSDR", "4KHDR240FPS", "2KHDR240FPS"]

    // MARK: Parsing

    // The manifest changes between macOS releases. Every level decodes leniently: an asset or category that isn't
    // an object, or a field of an unexpected type, costs that field or that entry, never the whole catalog.

    /// Decodes a `T`, or nil instead of throwing.
    private struct Lenient<T: Decodable>: Decodable {
        let value: T?
        init(from decoder: Decoder) throws { value = try? T(from: decoder) }
    }

    private enum Key: String, CodingKey {
        case assets, categories, id, accessibilityLabel, localizedNameKey, shotID, preferredOrder
    }

    private struct Manifest: Decodable {
        let assets: [Asset]
        let categories: [Category]

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            assets = (try? c.decode([Lenient<Asset>].self, forKey: .assets))?.compactMap(\.value) ?? []
            categories = (try? c.decode([Lenient<Category>].self, forKey: .categories))?.compactMap(\.value) ?? []
        }
    }

    private struct Asset: Decodable {
        let id: String?
        let accessibilityLabel: String?
        let localizedNameKey: String?
        let categories: [String]
        let shotID: String?
        let preferredOrder: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = AerialCatalog.text(c, .id)
            accessibilityLabel = AerialCatalog.text(c, .accessibilityLabel)
            localizedNameKey = AerialCatalog.text(c, .localizedNameKey)
            categories = (try? c.decode([Lenient<String>].self, forKey: .categories))?.compactMap(\.value) ?? []
            shotID = AerialCatalog.text(c, .shotID)
            preferredOrder = AerialCatalog.number(c, .preferredOrder)
        }
    }

    private struct Category: Decodable {
        let id: String?
        let localizedNameKey: String?
        let preferredOrder: Double?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Key.self)
            id = AerialCatalog.text(c, .id)
            localizedNameKey = AerialCatalog.text(c, .localizedNameKey)
            preferredOrder = AerialCatalog.number(c, .preferredOrder)
        }
    }

    /// A string field, or nil when it is missing, null or not a string.
    private static func text(_ c: KeyedDecodingContainer<Key>, _ key: Key) -> String? {
        try? c.decode(String.self, forKey: key)
    }

    /// A number field given as an integer, a fraction or numeric text; nil otherwise.
    private static func number(_ c: KeyedDecodingContainer<Key>, _ key: Key) -> Double? {
        if let value = try? c.decode(Int.self, forKey: key) { return Double(value) }
        if let value = try? c.decode(Double.self, forKey: key) { return value }
        if let value = try? c.decode(String.self, forKey: key) { return Double(value) }
        return nil
    }

    /// The aerials in `entries.json`, named from `localizedStrings` (the strings bundle for the user's language), in
    /// category order then the manifest's own order. Unreadable data gives an empty list; assets without a string id
    /// are skipped, a repeated id is kept once, and a field of the wrong type counts as missing.
    public static func parse(entriesJSON: Data, localizedStrings: [String: String]) -> [Aerial] {
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: entriesJSON)
        } catch {
            Log.error("wallpaper: unreadable aerial manifest: \(error)")
            return []
        }
        func localized(_ key: String?) -> String? {
            guard let key, let value = localizedStrings[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
            return value
        }
        var categoryName: [String: String] = [:]
        var categoryOrder: [String: Double] = [:]
        for (index, category) in manifest.categories.enumerated() {
            guard let id = category.id, !id.isEmpty else { continue }
            categoryOrder[id] = category.preferredOrder ?? Double(index)
            if let name = localized(category.localizedNameKey) {
                categoryName[id] = name
            } else if let key = category.localizedNameKey, !key.isEmpty {
                let bare = key.hasPrefix("AerialCategory") ? String(key.dropFirst("AerialCategory".count)) : key
                categoryName[id] = bare.isEmpty ? key : bare
            }
        }

        struct Entry { let aerial: Aerial; let categoryRank: Double; let order: Double; let index: Int }
        var seen = Set<String>()
        var entries: [Entry] = []
        for (index, asset) in manifest.assets.enumerated() {
            let id = (asset.id ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, seen.insert(id).inserted else { continue }
            let label = asset.accessibilityLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = localized(asset.localizedNameKey) ?? (label?.isEmpty == false ? label : nil) ?? asset.shotID ?? id
            let category = asset.categories.first { categoryName[$0] != nil }
            entries.append(Entry(aerial: Aerial(id: id, name: name, category: category.flatMap { categoryName[$0] }),
                                 categoryRank: category.flatMap { categoryOrder[$0] } ?? .infinity,
                                 order: asset.preferredOrder ?? .infinity, index: index))
        }
        return entries.sorted {
            ($0.categoryRank, $0.order, $0.index) < ($1.categoryRank, $1.order, $1.index)
        }.map(\.aerial)
    }

    // MARK: Localized names

    /// The strings for the user's language from a `.loctable` (a property list with one dictionary per locale),
    /// with English filling any key the chosen locale lacks. Unreadable data gives an empty dictionary.
    public static func localizedStrings(locTable: Data, preferredLanguages: [String]) -> [String: String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: locTable, format: nil) as? [String: Any] else { return [:] }
        var tables: [String: [String: String]] = [:]
        for (locale, value) in plist {
            if let table = value as? [String: String] { tables[locale] = table }
        }
        return merged(tables, preferredLanguages: preferredLanguages)
    }

    /// The strings for the user's language from a `TVIdleScreenStrings.bundle`: macOS 26's single
    /// `Localizable.nocache.loctable`, or older systems' `<lang>.lproj/Localizable.nocache.strings`.
    public static func localizedStrings(bundle: URL, preferredLanguages: [String]) -> [String: String] {
        let fm = FileManager.default
        let folders = [bundle.appending(path: "Contents/Resources", directoryHint: .isDirectory), bundle]
        for folder in folders {
            let table = folder.appending(path: "Localizable.nocache.loctable", directoryHint: .notDirectory)
            if let data = try? Data(contentsOf: table) {
                return localizedStrings(locTable: data, preferredLanguages: preferredLanguages)
            }
        }
        for folder in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { continue }
            var tables: [String: [String: String]] = [:]
            for name in names where name.hasSuffix(".lproj") {
                let lproj = folder.appending(path: name, directoryHint: .isDirectory)
                for file in ["Localizable.nocache.strings", "Localizable.strings"] {
                    if let data = try? Data(contentsOf: lproj.appending(path: file, directoryHint: .notDirectory)),
                       let table = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] {
                        tables[String(name.dropLast(".lproj".count))] = table
                        break
                    }
                }
            }
            if !tables.isEmpty { return merged(tables, preferredLanguages: preferredLanguages) }
        }
        return [:]
    }

    private static func merged(_ tables: [String: [String: String]], preferredLanguages: [String]) -> [String: String] {
        let english = tables["en"] ?? [:]
        guard let chosen = Bundle.preferredLocalizations(from: Array(tables.keys), forPreferences: preferredLanguages).first,
              let table = tables[chosen] else { return english }
        return english.merging(table) { _, localized in localized }
    }

    // MARK: Downloaded aerials

    /// True for a regular file with something in it (an interrupted download can leave an empty file).
    public static func isPlayableFile(_ url: URL) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber else { return false }
        return size.int64Value > 0
    }

    /// `aerials` with their videos and thumbnails located in `location`, keeping only those whose video is on disk.
    public static func downloaded(_ aerials: [Aerial], in location: AerialLocation,
                                  isPlayable: (URL) -> Bool = isPlayableFile,
                                  fileExists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> [Aerial] {
        aerials.compactMap { aerial in
            let candidates = location.videoFolders.map { $0.appending(path: "\(aerial.id).mov", directoryHint: .notDirectory) }
            guard let video = candidates.first(where: isPlayable) else { return nil }
            var located = aerial
            located.videoURL = video
            if let folder = location.thumbnails {
                let thumbnail = folder.appending(path: "\(aerial.id).png", directoryHint: .notDirectory)
                located.thumbnailURL = fileExists(thumbnail) ? thumbnail : nil
            }
            return located
        }
    }

    /// Every downloaded aerial on this Mac, from the first location that has each id. Reads only.
    public static func load(locations: [AerialLocation] = locations,
                            preferredLanguages: [String] = Locale.preferredLanguages) -> [Aerial] {
        var seen = Set<String>()
        var result: [Aerial] = []
        for location in locations {
            guard let data = try? Data(contentsOf: location.manifest) else { continue }
            let strings = localizedStrings(bundle: location.strings, preferredLanguages: preferredLanguages)
            for aerial in downloaded(parse(entriesJSON: data, localizedStrings: strings), in: location)
            where seen.insert(aerial.id).inserted {
                result.append(aerial)
            }
        }
        return result
    }
}
