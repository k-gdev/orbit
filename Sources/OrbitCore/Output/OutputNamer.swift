import Foundation

public enum OutputNamer {
    /// File name without extension; `.tar.gz` is stripped entirely, otherwise only the last extension.
    public static func stem(of url: URL) -> String {
        let name = url.lastPathComponent
        if name.lowercased().hasSuffix(".tar.gz") { return String(name.dropLast(7)) }
        return url.deletingPathExtension().lastPathComponent
    }

    /// `base.ext`, then `base-2.ext`, `base-3.ext`... An empty `ext` means no dot (folders).
    public static func uniqueURL(in folder: URL, base: String, ext: String, exists: (URL) -> Bool) -> URL {
        func make(_ name: String) -> URL {
            folder.appending(path: ext.isEmpty ? name : "\(name).\(ext)", directoryHint: ext.isEmpty ? .isDirectory : .notDirectory)
        }
        var candidate = make(base)
        var n = 2
        while exists(candidate) {
            candidate = make("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    public static func outputURL(for source: URL, suffix: String, ext: String, in folder: URL, exists: (URL) -> Bool) -> URL {
        let stem = stem(of: source)
        return uniqueURL(in: folder, base: suffix.isEmpty ? stem : "\(stem)-\(suffix)", ext: ext, exists: exists)
    }

    public static func numberedURLs(for source: URL, suffix: String, ext: String, count: Int, in folder: URL, exists: (URL) -> Bool) -> [URL] {
        let stem = stem(of: source)
        return (0..<max(count, 0)).map { n in
            let i = n + 1
            return uniqueURL(in: folder, base: "\(stem)-\(suffix)-\(i)", ext: ext, exists: exists)
        }
    }
}
