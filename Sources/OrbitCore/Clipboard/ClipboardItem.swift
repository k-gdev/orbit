import CryptoKit
import Foundation

/// What a clipboard entry holds.
public enum ClipboardKind: String, Codable, CaseIterable, Sendable {
    case text, richText, image, files
}

/// One entry of the clipboard history. The index stores only this small description; the content itself
/// (the text, the RTF, the PNG, the list of file paths) lives in a blob file named `payloadFile` inside
/// the history folder, so the index stays small however large a copy was.
public struct ClipboardItem: Codable, Identifiable, Hashable, Sendable {
    /// How many characters of text (or of file names) the preview keeps.
    public static let previewLimit = 200

    public var id: UUID
    public var kind: ClipboardKind
    /// The first 200 characters of the text (whitespace collapsed), "Image 1920 × 1080", or the file names.
    public var preview: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date: Date
    public var pinned: Bool
    /// Identifies the content (see `ClipboardHash`): copying the same thing again moves its entry up
    /// instead of adding a second one.
    public var contentHash: String
    /// The size of the stored content in bytes (what counts toward the size limits).
    public var byteSize: Int
    /// The blob's file name inside the history folder; nil for an entry that has no stored content.
    public var payloadFile: String?

    public init(id: UUID = UUID(), kind: ClipboardKind, preview: String, sourceBundleID: String? = nil,
                sourceName: String? = nil, date: Date, pinned: Bool = false, contentHash: String,
                byteSize: Int, payloadFile: String? = nil) {
        self.id = id
        self.kind = kind
        self.preview = preview
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
        self.pinned = pinned
        self.contentHash = contentHash
        self.byteSize = byteSize
        self.payloadFile = payloadFile
    }

    /// `text` shortened for a list row: surrounding whitespace dropped, every run of whitespace and
    /// line breaks collapsed to one space, cut to `previewLimit` characters.
    public static func makePreview(_ text: String) -> String {
        var out = ""
        var count = 0
        var pendingSpace = false
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if count + (pendingSpace ? 2 : 1) > previewLimit { break }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
            if count >= previewLimit { break }
        }
        return out
    }

    /// "just now", "5 min ago", "3 h ago", "Yesterday", "4 d ago".
    public static func ageLabel(for date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes) min ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours) h ago" }
        let days = hours / 24
        return days == 1 ? "Yesterday" : "\(days) d ago"
    }
}

/// The hash that makes two copies "the same". SHA-256 over the kind and the stored content, so the same
/// text copied as plain text and as rich text stay separate entries.
public enum ClipboardHash {
    public static func make(kind: ClipboardKind, payload: Data) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(kind.rawValue.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: payload)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// How the content of an entry is stored in its blob file.
public enum ClipboardPayload {
    /// The paths of a `.files` entry (stored as a JSON array of strings). Unreadable data gives `[]`.
    public static func filePaths(from data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }

    static func data(forFilePaths paths: [String]) -> Data {
        (try? JSONEncoder().encode(paths)) ?? Data("[]".utf8)
    }

    /// The file extension of the blob for each kind.
    public static func fileExtension(for kind: ClipboardKind) -> String {
        switch kind {
        case .text: "txt"
        case .richText: "rtf"
        case .image: "png"
        case .files: "json"
        }
    }
}

/// Something just read from the pasteboard, ready to become a history entry: the content as it will be
/// stored, a preview, and where it came from. Built by the app's pasteboard watcher; pure so it can be
/// tested.
public struct ClipboardCapture: Sendable {
    public var kind: ClipboardKind
    public var payload: Data
    public var preview: String
    public var sourceBundleID: String?
    public var sourceName: String?
    public var date: Date
    /// `ClipboardHash` of kind + payload when already computed (see `hashed()`); nil otherwise.
    public var contentHash: String?

    public init(kind: ClipboardKind, payload: Data, preview: String, sourceBundleID: String?,
                sourceName: String?, date: Date, contentHash: String? = nil) {
        self.kind = kind
        self.payload = payload
        self.preview = preview
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
        self.date = date
        self.contentHash = contentHash
    }

    /// This capture with its content hash computed now. Hashing a large payload takes a while, so the
    /// app does it on a background queue, before the capture reaches the history on the main thread.
    public func hashed() -> ClipboardCapture {
        var copy = self
        copy.contentHash = ClipboardHash.make(kind: kind, payload: payload)
        return copy
    }

    public static func text(_ string: String, sourceBundleID: String?, sourceName: String?, date: Date) -> ClipboardCapture {
        ClipboardCapture(kind: .text, payload: Data(string.utf8), preview: ClipboardItem.makePreview(string),
                         sourceBundleID: sourceBundleID, sourceName: sourceName, date: date)
    }

    /// `plain` is the text version that came with the RTF (used for the preview and for searching).
    public static func richText(rtf: Data, plain: String, sourceBundleID: String?, sourceName: String?, date: Date) -> ClipboardCapture {
        ClipboardCapture(kind: .richText, payload: rtf, preview: ClipboardItem.makePreview(plain),
                         sourceBundleID: sourceBundleID, sourceName: sourceName, date: date)
    }

    public static func image(png: Data, width: Int, height: Int, sourceBundleID: String?, sourceName: String?, date: Date) -> ClipboardCapture {
        ClipboardCapture(kind: .image, payload: png, preview: "Image \(width) × \(height)",
                         sourceBundleID: sourceBundleID, sourceName: sourceName, date: date)
    }

    public static func files(paths: [String], sourceBundleID: String?, sourceName: String?, date: Date) -> ClipboardCapture {
        let names = paths.map { ($0 as NSString).lastPathComponent }
        return ClipboardCapture(kind: .files, payload: ClipboardPayload.data(forFilePaths: paths),
                                preview: ClipboardItem.makePreview(names.joined(separator: ", ")),
                                sourceBundleID: sourceBundleID, sourceName: sourceName, date: date)
    }

    /// The history entry for this capture. `payloadFile` is the blob the content was (or will be) written to.
    public func makeItem(payloadFile: String?) -> ClipboardItem {
        ClipboardItem(kind: kind, preview: preview, sourceBundleID: sourceBundleID, sourceName: sourceName,
                      date: date, pinned: false, contentHash: contentHash ?? ClipboardHash.make(kind: kind, payload: payload),
                      byteSize: payload.count, payloadFile: payloadFile)
    }
}
