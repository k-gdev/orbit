import Foundation
@testable import OrbitCore

extension Fixtures {
    /// What `ffmpeg -i file` reports about a file's streams (the check for media AVFoundation can't read). Requires `hasFFmpeg`.
    struct StreamFacts {
        var duration: Double
        var videoSize: CGSize?
        var hasAudio: Bool
    }

    static func streamFacts(_ url: URL) async -> StreamFacts {
        do {
            let r = try await ProcessRunner.runCapturing(ffmpeg!, ["-hide_banner", "-i", FFmpeg.pathArg(url)])
            let re = try! NSRegularExpression(pattern: #"Video:[^\n]*?[ ,](\d{2,5})x(\d{2,5})[ ,\[]"#)
            let ns = r.stderr as NSString
            var size: CGSize?
            if let m = re.firstMatch(in: r.stderr, range: NSRange(location: 0, length: ns.length)),
               let w = Double(ns.substring(with: m.range(at: 1))), let h = Double(ns.substring(with: m.range(at: 2))) {
                size = CGSize(width: w, height: h)
            }
            return StreamFacts(duration: FFmpeg.parseDuration(r.stderr) ?? 0, videoSize: size,
                               hasAudio: FFmpeg.hasAudioStream(r.stderr))
        } catch {
            preconditionFailure("Fixtures.streamFacts: \(error)")
        }
    }

    /// An MKV of `w`×`h` made from a generated MOV, named `name` (so tests can use awkward file names).
    static func mkv(named name: String, seconds: Double, w: Int = 320, h: Int = 240, in dir: URL) async -> URL {
        let mov = await video("src-\(UUID().uuidString.prefix(6)).mov", seconds: seconds, w: w, h: h, in: dir)
        defer { try? FileManager.default.removeItem(at: mov) }
        let out = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            try await FFmpeg(executable: ffmpeg!).run(inputs: [mov], args: ["-c", "copy"], output: out, duration: nil, progress: { _ in })
        } catch {
            preconditionFailure("Fixtures.mkv(named:): \(error)")
        }
        return out
    }
}
