import Foundation
import os

public enum Log {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _fileURL: URL = defaultFileURL
    private static let logger = Logger(subsystem: "com.kevo.orbit", category: "app")

    public static var defaultFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Logs/Orbit/orbit.log")
    }

    public static var fileURL: URL {
        lock.lock(); defer { lock.unlock() }
        return _fileURL
    }

    public static func configure(fileURL: URL) {
        lock.lock(); defer { lock.unlock() }
        _fileURL = fileURL
    }

    public static func info(_ m: String) {
        logger.info("\(m, privacy: .public)")
        write(level: "INFO", m)
    }

    public static func error(_ m: String) {
        logger.error("\(m, privacy: .public)")
        write(level: "ERROR", m)
    }

    private static func write(level: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(ISO8601DateFormatter().string(from: Date())) [\(level)] \(message)\n"
        let fm = FileManager.default
        let url = _fileURL
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: url.path) {
                guard fm.createFile(atPath: url.path, contents: nil) else { return }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            logger.error("log write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
