import Foundation
@testable import OrbitCore

extension Fixtures {
    /// A folder `dir/name` holding `files` (relative path to contents; subfolders are created).
    static func tree(_ files: [String: String], name: String = "tree", in dir: URL) -> URL {
        let root = dir.appending(path: name, directoryHint: .isDirectory)
        do { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false) } catch {
            preconditionFailure("Fixtures.tree \(name): \(error)")
        }
        for (path, contents) in files { _ = file(path, contents, in: root) }
        return root
    }

    /// `dir/name` holding `text` gzipped (made with the system gzip).
    static func gzipFile(_ text: String, name: String, in dir: URL) -> URL {
        let out = dir.appending(path: name, directoryHint: .notDirectory)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        process.arguments = ["-c"]
        let input = Pipe()
        process.standardInput = input
        guard FileManager.default.createFile(atPath: out.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: out) else { preconditionFailure("Fixtures.gzipFile") }
        process.standardOutput = handle
        do {
            try process.run()
            try input.fileHandleForWriting.write(contentsOf: Data(text.utf8))
            try input.fileHandleForWriting.close()
        } catch { preconditionFailure("Fixtures.gzipFile: \(error)") }
        process.waitUntilExit()
        try? handle.close()
        return out
    }

    /// Entry names of a zip/tar/tgz, with `__MACOSX/` entries, `./` prefixes and trailing slashes removed.
    static func archiveEntries(_ archive: URL) async throws -> [String] {
        let r = try await ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-tf", archive.path])
        return r.stdout.split(separator: "\n").map { unescapeTar(String($0)) }
            .filter { !$0.hasPrefix("__MACOSX/") }
            .map { name in
                var n = name
                if n.hasPrefix("./") { n.removeFirst(2) }
                while n.hasSuffix("/") { n.removeLast() }
                return n
            }
            .filter { !$0.isEmpty }
    }

    /// bsdtar prints non-ASCII bytes as `\ooo` octal escapes (and decomposes accents); undo both.
    private static func unescapeTar(_ line: String) -> String {
        var bytes: [UInt8] = []
        let u = Array(line.utf8)
        var i = 0
        while i < u.count {
            if u[i] == 0x5C, i + 3 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 3)], as: UTF8.self), radix: 8) {
                bytes.append(v)
                i += 4
            } else {
                bytes.append(u[i])
                i += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self).precomposedStringWithCanonicalMapping
    }
}
