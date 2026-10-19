import CryptoKit
import Foundation

/// Small, natively playable stand-ins for media AVFoundation can't read (used by the editors).
/// A proxy is named after a hash of the source's path and modification time and is reused once made.
public enum ProxyMaker {
    public static var defaultCacheDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Caches/Orbit/proxies", directoryHint: .isDirectory)
    }

    public static func proxy(for src: URL, ffmpeg: FFmpeg, audioOnly: Bool,
                             cacheDirectory: URL = ProxyMaker.defaultCacheDirectory) async throws -> URL {
        let ext = audioOnly ? "m4a" : "mp4"
        let target = cacheDirectory.appending(path: "\(key(for: src)).\(ext)", directoryHint: .notDirectory)
        if FileManager.default.fileExists(atPath: target.path) { return target }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Encode to a scratch name and rename, so a half-written proxy is never mistaken for a finished one.
        let scratch = cacheDirectory.appending(path: "\(UUID().uuidString).partial.\(ext)", directoryHint: .notDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let args = audioOnly
            ? ["-vn", "-c:a", "aac", "-b:a", "192k"]
            : ["-c:v", "h264_videotoolbox", "-b:v", "3M", "-vf", "scale='min(1280,iw)':-2", "-c:a", "aac", "-b:a", "160k"]
        try await ffmpeg.run(inputs: [src], args: args, output: scratch, duration: nil, progress: { _ in })
        do {
            try FileManager.default.moveItem(at: scratch, to: target)
        } catch {
            // Another proxy job finished the same file first.
            if !FileManager.default.fileExists(atPath: target.path) { throw error }
        }
        return target
    }

    static func key(for src: URL) -> String {
        let mtime = (try? src.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let digest = SHA256.hash(data: Data("\(src.standardizedFileURL.path)\(mtime)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
