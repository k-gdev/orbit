import AppKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A copy as it came off the pasteboard on the main thread: raw bytes, nothing decoded. Turning it into
/// a `ClipboardCapture` (decoding text, parsing RTF, converting an image to PNG, hashing) can take a
/// while for big copies, so `makeCapture` is a pure function the app runs on a background queue.
public struct RawPasteboardCopy: Sendable {
    public enum Content: Sendable {
        /// The text as UTF-8 bytes.
        case text(Data)
        /// RTF bytes, and the plain-text version the source offered with it (parsed from the RTF if nil).
        case richText(rtf: Data, plain: Data?)
        /// An image in any format ImageIO reads (PNG, TIFF, ...).
        case image(Data)
        case files([String])
    }

    public var content: Content
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date: Date
    /// The source marked this copy concealed (a password) and the user keeps those: it becomes a masked,
    /// memory-only entry.
    public var concealed: Bool

    public init(content: Content, sourceBundleID: String?, sourceName: String?, date: Date, concealed: Bool = false) {
        self.content = content
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
        self.concealed = concealed
    }

    public enum Outcome: Sendable {
        case capture(ClipboardCapture)
        /// Not recorded, with the reason.
        case skipped(String)
    }

    /// Decodes, converts and hashes. `maxItemBytes` is judged against what would be STORED: the text,
    /// the RTF, or the PNG (not the possibly much larger TIFF it was converted from).
    public func makeCapture(maxItemBytes: Int) -> Outcome {
        switch makeUnflaggedCapture(maxItemBytes: maxItemBytes) {
        case .capture(let capture): .capture((concealed ? capture.concealing() : capture).hashed())
        case .skipped(let reason): .skipped(reason)
        }
    }

    /// The capture before it is masked (if it is concealed) and hashed.
    private func makeUnflaggedCapture(maxItemBytes: Int) -> Outcome {
        switch content {
        case .text(let data):
            guard data.count <= maxItemBytes else { return .skipped("larger than the per-copy limit") }
            let string = String(decoding: data, as: UTF8.self)
            guard !string.allSatisfy(\.isWhitespace) else { return .skipped("only whitespace") }
            return .capture(ClipboardCapture.text(string, sourceBundleID: sourceBundleID, sourceName: sourceName, date: date))

        case .richText(let rtf, let plainData):
            guard rtf.count <= maxItemBytes else { return .skipped("larger than the per-copy limit") }
            let plain = plainData.map { String(decoding: $0, as: UTF8.self) }
                ?? NSAttributedString(rtf: rtf, documentAttributes: nil)?.string ?? ""
            guard !plain.allSatisfy(\.isWhitespace) else { return .skipped("only whitespace") }
            return .capture(ClipboardCapture.richText(rtf: rtf, plain: plain, sourceBundleID: sourceBundleID,
                                                      sourceName: sourceName, date: date))

        case .image(let data):
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0 else {
                return .skipped("image could not be read")
            }
            let isPNG = CGImageSourceGetType(source) as String? == UTType.png.identifier
            // A PNG is stored as it is; anything else is re-encoded as PNG (the slow part).
            guard let png = isPNG ? data : Self.pngData(from: source) else { return .skipped("image could not be converted") }
            guard png.count <= maxItemBytes else { return .skipped("larger than the per-copy limit") }
            return .capture(ClipboardCapture.image(png: png, width: width, height: height, sourceBundleID: sourceBundleID,
                                                   sourceName: sourceName, date: date))

        case .files(let paths):
            return .capture(ClipboardCapture.files(paths: paths, sourceBundleID: sourceBundleID, sourceName: sourceName, date: date))
        }
    }

    /// The first image of `source` encoded as PNG with ImageIO (safe off the main thread).
    private static func pngData(from source: CGImageSource) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImageFromSource(destination, source, 0, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
