import Foundation

/// Packs, unpacks and repacks zip, tar and tar.gz archives (and unpacks rar and plain gz) with the
/// system tools. Every external call goes through `ProcessRunner` with an argument array, and every
/// path is absolute or follows `--`, so a file called `-rf 'q" ü.txt` is never read as an option.
public enum Archiver {
    private static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    private static let tar = URL(fileURLWithPath: "/usr/bin/tar")
    private static let gunzip = URL(fileURLWithPath: "/usr/bin/gunzip")

    /// What an archive held, unpacked into a scratch folder.
    public struct Unpacked: Sendable {
        /// The scratch folder the archive was unpacked into.
        public let folder: URL
        /// Its top-level items, `__MACOSX` excluded.
        public let items: [URL]
    }

    /// Packs `items` into the new file `to`. Several items are staged side by side in `temp` first
    /// (clones on APFS) so they sit at the top level of the archive; one item is packed in place.
    public static func pack(_ items: [URL], format: OutputFormat, to output: URL, temp: URL) async throws {
        guard !items.isEmpty else { throw OrbitError.unsupported("There is nothing to archive.") }
        guard output.pathExtension == "zip" || output.lastPathComponent.hasSuffix(".tar")
                || output.lastPathComponent.hasSuffix(".tar.gz") else {
            throw OrbitError.unsupported("Orbit can't make that kind of archive.")
        }
        try Task.checkCancellation()

        if items.count == 1 {
            let item = items[0]
            switch format {
            case .zip:
                // --keepParent on a file would also keep the folder around it; only folders need it.
                let isFolder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let flags = isFolder ? ["-c", "-k", "--sequesterRsrc", "--keepParent"] : ["-c", "-k", "--sequesterRsrc"]
                _ = try await ProcessRunner.run(ditto, flags + [item.path, output.path])
            case .tar, .tgz:
                try await runTar(create: format, output: output, directory: item.deletingLastPathComponent(),
                                 names: [item.lastPathComponent])
            default:
                throw OrbitError.unsupported("Orbit can't make that kind of archive.")
            }
            return
        }

        let stage = temp.appending(path: "stage", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        var names: [String] = []
        for item in items {
            try Task.checkCancellation()
            let name = uniqueName(item.lastPathComponent, taken: Set(names))
            try FileManager.default.copyItem(at: item, to: stage.appending(path: name))
            names.append(name)
        }
        switch format {
        case .zip:
            _ = try await ProcessRunner.run(ditto, ["-c", "-k", "--sequesterRsrc", stage.path, output.path])
        case .tar, .tgz:
            try await runTar(create: format, output: output, directory: stage, names: names)
        default:
            throw OrbitError.unsupported("Orbit can't make that kind of archive.")
        }
    }

    /// Unpacks `archive` into a new folder inside `temp`.
    public static func unpack(_ archive: DroppedItem, temp: URL) async throws -> Unpacked {
        try Task.checkCancellation()
        let folder = temp.appending(path: "x", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = archive.url
        switch archive.formatKey {
        case "zip":
            _ = try await ProcessRunner.run(ditto, ["-x", "-k", source.path, folder.path])
        case "tar", "tgz", "rar":
            _ = try await ProcessRunner.run(tar, ["-xf", source.path, "-C", folder.path])
        case "gz":
            var name = OutputNamer.stem(of: source)
            if name.isEmpty { name = "file" }
            _ = try await ProcessRunner.run(gunzip, ["-c", source.path], stdoutFile: folder.appending(path: name))
        default:
            throw OrbitError.unsupported("Orbit can't open this kind of archive.")
        }
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return Unpacked(folder: folder, items: contents)
    }

    /// Unpacks `archive` in `temp`, then moves the result to a URL the caller reserved: when the
    /// archive holds exactly one top-level item, `destination` gets that item (so there is no extra
    /// folder around it); otherwise it gets `nil` and receives the whole unpacked folder.
    /// Returns the final URL and the number of top-level items.
    public static func extract(_ archive: DroppedItem, temp: URL,
                               destination: (_ onlyItem: URL?) -> URL) async throws -> (url: URL, count: Int) {
        let unpacked = try await unpack(archive, temp: temp)
        guard !unpacked.items.isEmpty else { throw OrbitError.unsupported("This archive is empty.") }
        let single = unpacked.items.count == 1 ? unpacked.items[0] : nil
        let target = destination(single)
        try Task.checkCancellation()
        try FileManager.default.moveItem(at: single ?? unpacked.folder, to: target)
        return (target, unpacked.items.count)
    }

    /// Unpacks `archive` in `temp` and packs what it held into the new file `output`.
    public static func repack(_ archive: DroppedItem, to format: OutputFormat, output: URL, temp: URL) async throws {
        let unpacked = try await unpack(archive, temp: temp)
        guard !unpacked.items.isEmpty else { throw OrbitError.unsupported("This archive is empty.") }
        try await pack(unpacked.items, format: format, to: output, temp: temp)
    }

    // MARK: Helpers

    /// `-C directory` plus the names after `--`, so a leading dash in a name stays a name.
    private static func runTar(create format: OutputFormat, output: URL, directory: URL, names: [String]) async throws {
        let flags = format == .tgz ? "-czf" : "-cf"
        _ = try await ProcessRunner.run(tar, [flags, output.path, "-C", directory.path, "--"] + names)
    }

    /// `name`, or `stem-2.ext`, `stem-3.ext`… when `name` is already taken in the stage.
    private static func uniqueName(_ name: String, taken: Set<String>) -> String {
        guard taken.contains(name) else { return name }
        let url = URL(fileURLWithPath: name)
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(stem)-\(n)" : "\(stem)-\(n).\(ext)"
            if !taken.contains(candidate) { return candidate }
            n += 1
        }
    }
}
