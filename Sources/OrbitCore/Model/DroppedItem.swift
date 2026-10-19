import Foundation
import UniformTypeIdentifiers

public struct DroppedItem: Hashable, Sendable {
    public let url: URL
    public let type: UTType
    public let category: FileCategory
    public let formatKey: String

    public init(url: URL) {
        let result = FileClassifier.classify(url)
        self.url = url
        self.type = result.type
        self.category = result.category
        self.formatKey = result.formatKey
    }
}

public enum FileClassifier {
    private static let categoryByKey: [String: FileCategory] = {
        var table: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.image, ["png", "jpg", "jpeg", "heic", "heif", "webp", "tiff", "tif", "bmp", "gif", "ico", "avif", "svg"]),
            (.video, ["mp4", "mov", "m4v", "mkv", "webm", "avi", "wmv"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "ogg", "opus", "wma"]),
            (.pdf, ["pdf"]),
            (.document, ["docx", "doc", "pages", "rtf", "rtfd", "txt", "md", "markdown", "html", "htm", "textclipping"]),
            (.slides, ["pptx", "ppt", "key"]),
            (.spreadsheet, ["xlsx", "xls", "numbers", "ods", "csv", "tsv"]),
            (.subtitle, ["srt", "vtt"]),
            (.archive, ["zip", "tar", "gz", "tgz", "tar.gz", "rar"]),
        ]
        for (category, keys) in groups { for key in keys { table[key] = category } }
        return table
    }()

    private static let canonicalKey: [String: String] = [
        "jpeg": "jpg", "heif": "heic", "aif": "aiff", "htm": "html",
        "markdown": "md", "tar.gz": "tgz", "tgz": "tgz",
    ]

    private static let zipBasedKeys: Set<String> = ["docx", "xlsx", "pptx", "epub", "ods", "pages", "key", "numbers"]

    public static func classify(_ url: URL) -> (type: UTType, category: FileCategory, formatKey: String) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        let isDirectory = values?.isDirectory ?? false
        let isPackage = values?.isPackage ?? false
        let extKey = extensionKey(of: url)

        if isDirectory {
            guard isPackage else { return (.folder, .folder, "") }
            if isKnownPackageExtension(extKey), let category = categoryByKey[extKey] {
                return (bestType(for: extKey), category, extKey)
            }
            return (.package, .other, extKey)
        }

        var key = extKey
        if let sniffed = sniff(url) {
            if sniffed == "zip" {
                if !zipBasedKeys.contains(extKey) { key = "zip" }
            } else {
                key = sniffed
            }
        }
        let category = categoryByKey[key] ?? .other
        return (bestType(for: key), category, key)
    }

    private static func isKnownPackageExtension(_ key: String) -> Bool {
        ["rtfd", "pages", "key", "numbers"].contains(key)
    }

    private static func extensionKey(of url: URL) -> String {
        let name = url.lastPathComponent.lowercased()
        if name.hasSuffix(".tar.gz") { return "tgz" }
        let ext = url.pathExtension.lowercased()
        return canonicalKey[ext] ?? ext
    }

    private static func bestType(for key: String) -> UTType {
        guard !key.isEmpty else { return .data }
        if key == "tgz" { return UTType(filenameExtension: "gz") ?? .data }
        return UTType(filenameExtension: key) ?? .data
    }

    private static func sniff(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 16), data.count >= 4 else { return nil }
        let b = [UInt8](data)
        func ascii(_ range: Range<Int>) -> String? {
            guard range.upperBound <= b.count else { return nil }
            return String(bytes: b[range], encoding: .isoLatin1)
        }
        if b.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return "png" }
        if b.starts(with: [0xFF, 0xD8, 0xFF]) { return "jpg" }
        if ascii(0..<4) == "GIF8" { return "gif" }
        if ascii(0..<4) == "%PDF" { return "pdf" }
        if ascii(0..<4) == "RIFF" {
            if ascii(8..<12) == "WEBP" { return "webp" }
            if ascii(8..<12) == "WAVE" { return "wav" }
        }
        if ascii(4..<8) == "ftyp", let brand = ascii(8..<12) {
            switch brand {
            case "heic", "heix", "mif1": return "heic"
            case "avif": return "avif"
            case "qt  ": return "mov"
            case "isom", "mp41", "mp42": return "mp4"
            case "M4A ": return "m4a"
            default: return nil
            }
        }
        if b.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return "zip" }
        return nil
    }
}
