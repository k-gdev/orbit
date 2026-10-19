import AVFoundation
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
    /// A rotated clip whose `preferredTransform` has no translation, the way `ffmpeg -display_rotation` writes it
    /// (a=0 b=-1 c=1 d=0 tx=0 ty=0). The frames are stored sideways at `h`×`w`, so the picture is `w`×`h` on screen.
    /// `Fixtures.video(rotated:)` writes an Apple-normalised matrix with a translation instead.
    static func videoRotatedWithoutTranslation(_ name: String, seconds: Double, w: Int, h: Int, audio: Bool = true,
                                               in dir: URL) async -> URL {
        let url = await video(name, seconds: seconds, w: w, h: h, audio: audio, rotated: true, in: dir)
        var data = (try? Data(contentsOf: url)) ?? Data()
        let tag = Data("tkhd".utf8)
        func word(_ at: Int) -> Int32 { Int32(bitPattern: data[at..<at + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }) }
        func put(_ value: Int32, at: Int) {
            let bits = UInt32(bitPattern: value)
            for i in 0..<4 { data[at + i] = UInt8(truncatingIfNeeded: bits >> UInt32(24 - 8 * i)) }
        }
        var patched = 0
        var cursor = data.startIndex
        while let hit = data.range(of: tag, in: cursor..<data.endIndex) {
            cursor = hit.upperBound
            let version = data[hit.upperBound]
            guard version <= 1 else { continue }
            let matrix = hit.lowerBound + 8 + (version == 0 ? 20 : 32) + 16
            guard matrix + 36 <= data.count, word(matrix + 4) != 0 else { continue }   // b == 0: not the rotated video track
            put(0, at: matrix); put(-0x10000, at: matrix + 4)
            put(0x10000, at: matrix + 12); put(0, at: matrix + 16)
            put(0, at: matrix + 24); put(0, at: matrix + 28)
            patched += 1
        }
        precondition(patched == 1, "Fixtures.videoRotatedWithoutTranslation: patched \(patched) tracks")
        do { try data.write(to: url) } catch { preconditionFailure("Fixtures.videoRotatedWithoutTranslation: \(error)") }
        return url
    }

    /// A clip whose audio runs `audioSeconds` while the video stops at `videoSeconds` (phone clips often end like this).
    static func videoWithLongerAudio(_ name: String, videoSeconds: Double, audioSeconds: Double, w: Int, h: Int,
                                     in dir: URL) async -> URL {
        let pictures = await video("pic-\(UUID().uuidString.prefix(6)).mov", seconds: videoSeconds, w: w, h: h, audio: false, in: dir)
        let sound = await video("snd-\(UUID().uuidString.prefix(6)).mov", seconds: audioSeconds, w: 64, h: 48, in: dir)
        defer { try? FileManager.default.removeItem(at: pictures); try? FileManager.default.removeItem(at: sound) }
        let out = dir.appending(path: name, directoryHint: .notDirectory)
        do {
            let composition = AVMutableComposition()
            let videoAsset = AVURLAsset(url: pictures), audioAsset = AVURLAsset(url: sound)
            let videoSource = try await videoAsset.loadTracks(withMediaType: .video)[0]
            let audioSource = try await audioAsset.loadTracks(withMediaType: .audio)[0]
            try composition.insert(videoSource, range: try await videoSource.load(.timeRange))
            try composition.insert(audioSource, range: try await audioSource.load(.timeRange))
            try await MediaExport.export(composition, preset: AVAssetExportPresetPassthrough, fileType: .mov, to: out,
                                         progress: { _ in })
        } catch {
            preconditionFailure("Fixtures.videoWithLongerAudio: \(error)")
        }
        return out
    }
}
