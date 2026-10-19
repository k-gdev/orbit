import Foundation

/// Packs a folder into a zip with `/usr/bin/zip` (argument arrays only, no shell).
public enum ZipPackager {
    private static let zipTool = URL(fileURLWithPath: "/usr/bin/zip")

    /// Zips the contents of `directory` into a new file at `to`. Refuses when `to` already exists.
    /// If `storedFirst` is given, that entry is written first and uncompressed (EPUB and ODS `mimetype`).
    /// The archive is built beside a scratch name and moved into place, so a failure leaves no partial `to`.
    public static func zip(directory: URL, to: URL, storedFirst: String? = nil) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: to.path) else {
            throw OrbitError.unsupported("Refusing to overwrite existing file \(to.lastPathComponent).")
        }
        let staging = fm.temporaryDirectory.appending(path: "orbit-zip-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        // zip appends ".zip" to names without an extension, so build under a name that always has one.
        let out = staging.appending(path: "package.zip", directoryHint: .notDirectory)

        if let storedFirst {
            _ = try await ProcessRunner.run(zipTool, ["-X0", out.path, storedFirst], currentDirectory: directory)
            _ = try await ProcessRunner.run(zipTool, ["-Xr9D", out.path, ".", "-x", storedFirst], currentDirectory: directory)
        } else {
            _ = try await ProcessRunner.run(zipTool, ["-Xr9D", out.path, "."], currentDirectory: directory)
        }
        try fm.moveItem(at: out, to: to)
    }

    /// Writes `entries` (relative path, data) into a scratch folder, zips it to `to`, and removes the scratch folder.
    static func package(entries: [(path: String, data: Data)], storedFirst: String? = nil, to: URL) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: to.path) else {
            throw OrbitError.unsupported("Refusing to overwrite existing file \(to.lastPathComponent).")
        }
        let root = fm.temporaryDirectory.appending(path: "orbit-pkg-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: root) }
        for entry in entries {
            let url = root.appending(path: entry.path, directoryHint: .notDirectory)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try entry.data.write(to: url, options: .withoutOverwriting)
        }
        try await zip(directory: root, to: to, storedFirst: storedFirst)
    }
}

/// XML text helpers shared by the writers.
enum XMLText {
    /// Escapes &, <, > and quotes, and drops characters XML 1.0 cannot carry.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for u in s.unicodeScalars {
            switch u {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            case "\t", "\n", "\r": out.unicodeScalars.append(u)
            default:
                let v = u.value
                if v >= 0x20 && v != 0xFFFE && v != 0xFFFF && !(0xD800...0xDFFF).contains(v) { out.unicodeScalars.append(u) }
            }
        }
        return out
    }

    static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n"
}
