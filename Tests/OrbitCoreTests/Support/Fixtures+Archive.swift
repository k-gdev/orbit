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

    // MARK: Hostile archives (hand-built, so the entries are exactly what the test says)

    struct HostileEntry { let name: String; let link: String?; let data: String }

    /// A ustar archive. `link` makes the entry a symlink to that target; otherwise a regular file.
    static func hostileTar(_ entries: [HostileEntry], at url: URL) {
        func field(_ s: String, _ n: Int) -> [UInt8] { Array((Array(s.utf8) + [UInt8](repeating: 0, count: n)).prefix(n)) }
        func octal(_ v: Int, _ n: Int) -> [UInt8] { field(String(format: "%0\(n - 1)o", v), n) }
        var out = Data()
        for e in entries {
            let body = e.link == nil ? Array(e.data.utf8) : []
            var h = [UInt8](repeating: 0, count: 512)
            func put(_ b: [UInt8], _ at: Int) { h.replaceSubrange(at..<(at + b.count), with: b) }
            put(field(e.name, 100), 0); put(octal(0o644, 8), 100); put(octal(0, 8), 108); put(octal(0, 8), 116)
            put(octal(body.count, 12), 124); put(octal(0, 12), 136)
            put([UInt8](repeating: 0x20, count: 8), 148)
            h[156] = e.link == nil ? 0x30 : 0x32
            put(field(e.link ?? "", 100), 157); put(field("ustar", 6), 257); put([0x30, 0x30], 263)
            put(field(String(format: "%06o", h.reduce(0) { $0 + Int($1) }), 7), 148); h[155] = 0x20
            out.append(contentsOf: h)
            out.append(contentsOf: body)
            out.append(Data(repeating: 0, count: (512 - body.count % 512) % 512))
        }
        out.append(Data(repeating: 0, count: 1024))
        FileManager.default.createFile(atPath: url.path, contents: out)
    }

    /// A stored (uncompressed) zip with the given file entries; names are written verbatim.
    static func hostileZip(_ entries: [(name: String, data: String)], at url: URL) {
        func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
        func crc(_ d: [UInt8]) -> Int {
            var c: UInt32 = 0xFFFF_FFFF
            for b in d { c ^= UInt32(b); for _ in 0..<8 { c = (c >> 1) ^ (0xEDB8_8320 & (0 &- (c & 1))) } }
            return Int(~c)
        }
        var out: [UInt8] = [], central: [UInt8] = []
        for e in entries {
            let name = Array(e.name.utf8), body = Array(e.data.utf8), offset = out.count
            let common = le(10, 2) + le(0, 2) + le(0, 2) + le(0, 2) + le(0x21, 2) + le(crc(body), 4)
                + le(body.count, 4) + le(body.count, 4) + le(name.count, 2) + le(0, 2)
            out += le(0x04034b50, 4) + common + name + body
            central += le(0x02014b50, 4) + le(0x031E, 2) + common + le(0, 2) + le(0, 2) + le(0, 2)
                + le(0, 4) + le(0, 4)
            central.replaceSubrange((central.count - 4)..<central.count, with: le(offset, 4))
            central += name
        }
        let start = out.count
        out += central + le(0x06054b50, 4) + le(0, 2) + le(0, 2) + le(entries.count, 2) + le(entries.count, 2)
            + le(central.count, 4) + le(start, 4) + le(0, 2)
        FileManager.default.createFile(atPath: url.path, contents: Data(out))
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
