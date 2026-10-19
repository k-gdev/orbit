import Foundation
@testable import OrbitCore

/// Helpers for inspecting zip-based document packages (xlsx, ods, pptx, epub).
extension Fixtures {
    private static let unzip = URL(fileURLWithPath: "/usr/bin/unzip")

    /// Entry names in archive order.
    static func unzipList(_ url: URL) async throws -> [String] {
        let r = try await ProcessRunner.run(unzip, ["-Z1", url.path])
        return r.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    /// One entry's contents as text, byte for byte.
    static func unzipRead(_ url: URL, _ entry: String) async throws -> String {
        // unzip treats entry names as wildcard patterns, so "[Content_Types].xml" needs its brackets escaped.
        let literal = entry.reduce(into: "") { out, ch in
            if "[]*?\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return try await ProcessRunner.run(unzip, ["-p", url.path, literal]).stdout
    }

    /// The compression method column of `unzip -v` for `entry`, for example `Stored` or `Defl:N`.
    static func zipMethod(_ url: URL, _ entry: String) async throws -> String {
        let r = try await ProcessRunner.run(unzip, ["-v", url.path])
        for line in r.stdout.split(separator: "\n") where line.hasSuffix(" " + entry) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            if cols.count >= 2 { return String(cols[1]) }
        }
        return ""
    }
}
