import AppKit
import OrbitCore

/// The app a copy came from.
struct ClipboardSourceApp: Equatable {
    var bundleID: String?
    var name: String?
}

/// What the user's rules say about a copy: apps to ignore, the size limits and whether copied passwords are kept.
struct PasteboardPolicy {
    var ignoredBundleIDs: [String]
    var limits: ClipboardLimits
    var recordPasswords = false
}

/// What reading the pasteboard produced.
enum PasteboardRead {
    /// Nothing the history stores (an empty pasteboard, or only types it doesn't keep).
    case nothing
    /// Deliberately not recorded, with the reason (for the debug check and the log).
    case skipped(String)
    /// The raw bytes of a copy. Decoding, converting and hashing them is `RawPasteboardCopy.makeCapture`'s
    /// job, run off the main thread.
    case copy(RawPasteboardCopy)
}

/// Reads what is on a pasteboard into a `RawPasteboardCopy`: file copies, then text (rich text when RTF
/// came along), then images. Takes any `NSPasteboard`, so `--check-clipboard` can exercise it on a
/// private named pasteboard instead of the user's real one.
///
/// This runs on the main thread inside the poll, so it only fetches bytes and checks their size: no
/// decoding, parsing, image conversion or hashing happens here.
enum PasteboardReader {
    /// nspasteboard.org: apps may name themselves here (more accurate than "whoever is frontmost").
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// `afterTypes` is called once the marker types have been read and checked, before any content is
    /// read (a test hook: `--check-clipboard` changes the pasteboard there to prove a mid-read change is caught).
    @MainActor
    static func read(_ pasteboard: NSPasteboard, policy: PasteboardPolicy, frontmost: ClipboardSourceApp?, now: Date,
                     afterTypes: (() -> Void)? = nil) -> PasteboardRead {
        // The marker types and the content are read in separate calls. If the pasteboard changes in
        // between (a password manager copying right after another app), the markers checked belong to
        // the OLD content and the data read to the NEW: so the change count is compared before and after
        // and the whole read is discarded when it moved. The next poll sees the new count and reads again.
        let before = pasteboard.changeCount
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let source = sourceApp(of: pasteboard, frontmost: frontmost)
        let verdict = PasteboardFilter.verdict(types: types, sourceBundleID: source.bundleID,
                                               ignoredBundleIDs: policy.ignoredBundleIDs, recordPasswords: policy.recordPasswords)
        guard verdict != .skip else {
            return .skipped("marked concealed or from an ignored app")
        }
        afterTypes?()
        let result = readContents(pasteboard, policy: policy, source: source, now: now, concealed: verdict == .recordConcealed)
        guard pasteboard.changeCount == before else { return .skipped("the pasteboard changed while it was being read") }
        return result
    }

    @MainActor
    private static func readContents(_ pasteboard: NSPasteboard, policy: PasteboardPolicy, source: ClipboardSourceApp, now: Date,
                                     concealed: Bool) -> PasteboardRead {
        func raw(_ content: RawPasteboardCopy.Content) -> PasteboardRead {
            .copy(RawPasteboardCopy(content: content, sourceBundleID: source.bundleID, sourceName: source.name, date: now, concealed: concealed))
        }
        let maxBytes = policy.limits.maxItemBytes

        // Files copied in Finder: the paths, whatever text or icon image came along with them.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            return raw(.files(urls.map(\.path)))
        }

        // Text, rich when the source also offered RTF. The size is checked on the bytes, before any
        // String is made from them.
        let text = textData(pasteboard)
        if let rtf = pasteboard.data(forType: .rtf), rtf.count <= maxBytes {
            return raw(.richText(rtf: rtf, plain: text.flatMap { $0.count <= maxBytes ? $0 : nil }))
        }
        if let text {
            return text.count <= maxBytes ? raw(.text(text)) : .skipped("larger than the per-copy limit")
        }

        // Images. A PNG (a screenshot) is stored as it is, so it is judged by its own size. Anything else
        // (TIFF, usually) is converted to PNG later and judged by the PNG it becomes; here it only has to
        // be small enough to be worth converting.
        if let png = pasteboard.data(forType: .png) {
            return png.count <= maxBytes ? raw(.image(png)) : .skipped("larger than the per-copy limit")
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            return tiff.count <= policy.limits.maxRawImageBytes ? raw(.image(tiff)) : .skipped("image is far larger than the per-copy limit")
        }
        return .nothing
    }

    /// The text as UTF-8 bytes. `data(forType:)` hands over the bytes without making a String; only a
    /// pasteboard that offers some other text encoding needs the String conversion.
    @MainActor
    private static func textData(_ pasteboard: NSPasteboard) -> Data? {
        if let data = pasteboard.data(forType: .string) { return data }
        return pasteboard.string(forType: .string).map { Data($0.utf8) }
    }

    /// The app named by the pasteboard's own source marker, else whoever is frontmost.
    @MainActor
    private static func sourceApp(of pasteboard: NSPasteboard, frontmost: ClipboardSourceApp?) -> ClipboardSourceApp {
        if let id = pasteboard.string(forType: sourceType)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return ClipboardSourceApp(bundleID: id, name: AppLookup.name(forBundleID: id) ?? frontmost?.name)
        }
        return frontmost ?? ClipboardSourceApp(bundleID: nil, name: nil)
    }
}

/// App names and icons by bundle id, cached (the list shows the same few apps over and over).
@MainActor
enum AppLookup {
    private static var names: [String: String?] = [:]
    private static var icons: [String: NSImage?] = [:]

    static func name(forBundleID id: String) -> String? {
        if let cached = names[id] { return cached }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map {
            FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "")
        }
        names[id] = found
        return found
    }

    static func icon(forBundleID id: String) -> NSImage? {
        if let cached = icons[id] { return cached }
        let found = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[id] = found
        return found
    }

    /// The frontmost app right now, as a copy's source.
    static func frontmost() -> ClipboardSourceApp {
        let app = NSWorkspace.shared.frontmostApplication
        return ClipboardSourceApp(bundleID: app?.bundleIdentifier, name: app?.localizedName)
    }
}
