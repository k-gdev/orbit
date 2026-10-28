import AppKit
import ImageIO
import OrbitCore

/// The app a copy came from.
struct ClipboardSourceApp: Equatable {
    var bundleID: String?
    var name: String?
}

/// What the user's rules say about a copy: apps to ignore and the biggest copy to store.
struct PasteboardPolicy {
    var ignoredBundleIDs: [String]
    var maxItemBytes: Int
}

/// What reading the pasteboard produced.
enum PasteboardRead {
    /// Nothing the history stores (an empty pasteboard, or only types it doesn't keep).
    case nothing
    /// Deliberately not recorded, with the reason (for the debug check and the log).
    case skipped(String)
    case capture(ClipboardCapture)
}

/// Turns the contents of a pasteboard into a `ClipboardCapture`: file copies, then text (rich text when
/// RTF came along), then images. Takes any `NSPasteboard`, so `--check-clipboard` can exercise it on a
/// private named pasteboard instead of the user's real one.
enum PasteboardReader {
    /// nspasteboard.org: apps may name themselves here (more accurate than "whoever is frontmost").
    static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    @MainActor
    static func read(_ pasteboard: NSPasteboard, policy: PasteboardPolicy, frontmost: ClipboardSourceApp?, now: Date) -> PasteboardRead {
        let types = (pasteboard.types ?? []).map(\.rawValue)
        let source = sourceApp(of: pasteboard, frontmost: frontmost)
        guard PasteboardFilter.shouldRecord(types: types, sourceBundleID: source.bundleID, ignoredBundleIDs: policy.ignoredBundleIDs) else {
            return .skipped("marked concealed or from an ignored app")
        }

        // Files copied in Finder: the paths, whatever text or icon image came along with them.
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            let capture = ClipboardCapture.files(paths: urls.map(\.path), sourceBundleID: source.bundleID, sourceName: source.name, date: now)
            return admit(capture, policy: policy)
        }

        // Text, rich when the source also offered RTF.
        let string = pasteboard.string(forType: .string)
        let rtf = pasteboard.data(forType: .rtf)
        if let rtf, rtf.count <= policy.maxItemBytes {
            let plain = string ?? NSAttributedString(rtf: rtf, documentAttributes: nil)?.string ?? ""
            if !plain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return admit(.richText(rtf: rtf, plain: plain, sourceBundleID: source.bundleID, sourceName: source.name, date: now), policy: policy)
            }
        }
        if let string {
            guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .skipped("only whitespace") }
            return admit(.text(string, sourceBundleID: source.bundleID, sourceName: source.name, date: now), policy: policy)
        }

        // Images (a screenshot is PNG already; most other apps offer TIFF, which is stored as PNG).
        if let png = pasteboard.data(forType: .png) {
            return image(png, policy: policy, source: source, now: now)
        }
        if let tiff = pasteboard.data(forType: .tiff) {
            guard policy.maxItemBytes >= tiff.count else { return .skipped("image is larger than the per-copy limit") }
            guard let converted = pngData(fromImageData: tiff) else { return .skipped("image could not be read") }
            return image(converted, policy: policy, source: source, now: now)
        }
        return .nothing
    }

    // MARK: Pieces

    @MainActor
    private static func image(_ png: Data, policy: PasteboardPolicy, source: ClipboardSourceApp, now: Date) -> PasteboardRead {
        guard let size = pixelSize(of: png) else { return .skipped("image could not be read") }
        return admit(.image(png: png, width: size.width, height: size.height,
                            sourceBundleID: source.bundleID, sourceName: source.name, date: now), policy: policy)
    }

    private static func admit(_ capture: ClipboardCapture, policy: PasteboardPolicy) -> PasteboardRead {
        capture.payload.count <= policy.maxItemBytes ? .capture(capture) : .skipped("larger than the per-copy limit")
    }

    /// The app named by the pasteboard's own source marker, else whoever is frontmost.
    @MainActor
    private static func sourceApp(of pasteboard: NSPasteboard, frontmost: ClipboardSourceApp?) -> ClipboardSourceApp {
        if let id = pasteboard.string(forType: sourceType)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty {
            return ClipboardSourceApp(bundleID: id, name: AppLookup.name(forBundleID: id) ?? frontmost?.name)
        }
        return frontmost ?? ClipboardSourceApp(bundleID: nil, name: nil)
    }

    static func pixelSize(of imageData: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// PNG bytes for any image data the system can decode (TIFF from the pasteboard, usually).
    static func pngData(fromImageData data: Data) -> Data? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return rep.representation(using: .png, properties: [:])
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
