import CoreGraphics
import Foundation

/// The video tools for sources AVFoundation can't read or write (mkv, webm, avi, wmv, odd mp4s). Same
/// operations as `VideoTools`; the result keeps the source's container, so the output path's extension
/// picks the codecs whenever a tool has to re-encode.
public enum VideoToolsFFmpeg {
    public typealias Progress = VideoTools.Progress

    /// What `ffmpeg -i` reports about a file.
    public struct Probe: Equatable, Sendable {
        public var duration: Double
        /// The size on screen (rotation applied); nil when there is no video.
        public var videoSize: CGSize?
        public var hasAudio: Bool
        /// Codec, profile, pixel format, frame size, frame rate and rotation of each video stream, and
        /// codec, sample rate, channel layout and sample format of each audio stream (bitrates left out).
        /// Clips can be joined by stream copy only when these match.
        public var streams: String = ""
    }

    public static func probe(_ url: URL, ffmpeg: FFmpeg) async throws -> Probe {
        let result = try await ProcessRunner.runCapturing(ffmpeg.executable, ["-hide_banner", "-i", FFmpeg.pathArg(url)])
        guard let duration = FFmpeg.parseDuration(result.stderr) else {
            throw OrbitError.unsupported("Couldn't read the duration of \(url.lastPathComponent).")
        }
        return Probe(duration: duration, videoSize: parseVideoSize(result.stderr), hasAudio: FFmpeg.hasAudioStream(result.stderr),
                     streams: streamSignature(result.stderr))
    }

    /// One normalized line per video and audio stream of `ffmpeg -i` output: the stream description with
    /// bitrates, timebases, codec tags and disposition removed, plus the video's rotation.
    static func streamSignature(_ stderr: String) -> String {
        let codecTag = try! NSRegularExpression(pattern: #"\s*\([^()]*/ 0x[0-9A-Fa-f]+\)"#)
        let disposition = try! NSRegularExpression(pattern: #"\s*\((default|forced|attached pic|dependent|hearing impaired|visual impaired|original|dub|comment|lyrics|karaoke|clean effects|captions|descriptions|metadata)\)"#)
        let rotation = try! NSRegularExpression(pattern: #"rotation of (-?\d+(?:\.\d+)?) degrees"#)
        var lines: [String] = []
        let all = stderr.components(separatedBy: .newlines)
        for (index, line) in all.enumerated() where line.contains("Stream #") {
            guard let kind = ["Video: ", "Audio: "].first(where: { line.contains($0) }),
                  let start = line.range(of: kind) else { continue }
            var text = String(line[start.upperBound...])
            for re in [codecTag, disposition] {
                text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            }
            let fields = text.components(separatedBy: ", ").map { $0.trimmingCharacters(in: .whitespaces) }.filter { field in
                !(field.hasSuffix(" kb/s") || field.hasSuffix(" tbr") || field.hasSuffix(" tbn") || field.hasSuffix(" tbc"))
            }
            var signature = kind + fields.joined(separator: ", ")
            if kind == "Video: " {
                // Side data (e.g. "displaymatrix: rotation of -90.00 degrees") follows on the next lines.
                for next in all.dropFirst(index + 1).prefix(while: { !$0.contains("Stream #") }) {
                    let ns = next as NSString
                    if let m = rotation.firstMatch(in: next, range: NSRange(location: 0, length: ns.length)) {
                        signature += ", rotation \(ns.substring(with: m.range(at: 1)))"
                    }
                }
            }
            lines.append(signature)
        }
        return lines.joined(separator: "\n")
    }

    /// The first video stream's size from `ffmpeg -i` output, swapped when the stream is rotated a quarter turn.
    static func parseVideoSize(_ stderr: String) -> CGSize? {
        let sizePattern = try! NSRegularExpression(pattern: #"Stream #[^\n]*Video:[^\n]*?[ ,](\d{2,5})x(\d{2,5})[ ,\[]"#)
        let ns = stderr as NSString
        guard let match = sizePattern.firstMatch(in: stderr, range: NSRange(location: 0, length: ns.length)),
              let w = Double(ns.substring(with: match.range(at: 1))),
              let h = Double(ns.substring(with: match.range(at: 2))) else { return nil }
        let rotationPattern = try! NSRegularExpression(pattern: #"rotation of (-?\d+(?:\.\d+)?) degrees"#)
        if let r = rotationPattern.firstMatch(in: stderr, range: NSRange(location: 0, length: ns.length)),
           let degrees = Double(ns.substring(with: r.range(at: 1))) {
            let turns = Int((degrees / 90).rounded())
            if abs(turns) % 2 == 1 { return CGSize(width: h, height: w) }
        }
        return CGSize(width: w, height: h)
    }

    // MARK: Stream-copy tools

    public static func trim(_ src: URL, range: ClosedRange<Double>, to output: URL, ffmpeg: FFmpeg,
                            progress: @escaping Progress) async throws {
        let duration = try await ffmpeg.duration(of: src)
        let start = max(range.lowerBound, 0), end = min(range.upperBound, duration)
        guard end - start >= 0.01 else { throw OrbitError.unsupported("The part to keep is outside this video.") }
        try await ffmpeg.run(inputs: [src], args: trimArgs(start, end), output: output, duration: end - start, progress: progress)
    }

    public static func split(_ src: URL, at points: [Double], to outputs: [URL], ffmpeg: FFmpeg,
                             progress: @escaping Progress) async throws {
        guard outputs.count == points.count + 1 else { throw OrbitError.unsupported("Choose where to split first.") }
        let duration = try await ffmpeg.duration(of: src)
        guard !points.isEmpty, zip(points, points.dropFirst()).allSatisfy({ $0 < $1 }),
              points[0] > 0, points[points.count - 1] < duration else {
            throw OrbitError.unsupported("The split points must be in order and inside the video.")
        }
        let edges = [0] + points + [duration]
        let count = Double(outputs.count)
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            let base = Double(index)
            try await ffmpeg.run(inputs: [src], args: trimArgs(edges[index], edges[index + 1]), output: output,
                                 duration: edges[index + 1] - edges[index], progress: { progress((base + $0) / count) })
        }
        progress(1)
    }

    public static func mute(_ src: URL, to output: URL, ffmpeg: FFmpeg, progress: @escaping Progress) async throws {
        let duration = try? await ffmpeg.duration(of: src)
        // Every stream but the audio (other subtitle tracks, attachments) is kept.
        try await ffmpeg.run(inputs: [src], args: ["-map", "0", "-map", "-0:a", "-dn", "-c", "copy"], output: output,
                             duration: duration, progress: progress)
    }

    public static func removeMetadata(_ src: URL, to output: URL, ffmpeg: FFmpeg, progress: @escaping Progress) async throws {
        let duration = try? await ffmpeg.duration(of: src)
        try await ffmpeg.run(inputs: [src], args: ["-map", "0", "-dn", "-map_metadata", "-1", "-c", "copy"], output: output,
                             duration: duration, progress: progress)
    }

    // MARK: Re-encoding tools

    public static func speed(_ src: URL, factor: Double, to output: URL, ffmpeg: FFmpeg, progress: @escaping Progress) async throws {
        guard factor.isFinite, factor > 0 else { throw OrbitError.unsupported("Choose a speed first.") }
        let info = try await probe(src, ffmpeg: ffmpeg)
        // -sn: subtitles can't be retimed by a filter, so they would drift out of sync.
        var args = ["-sn", "-filter:v", "setpts=PTS/\(number(factor))"]
        if info.hasAudio { args += ["-filter:a", atempoChain(factor).joined(separator: ",")] }
        try await ffmpeg.run(inputs: [src], args: args + reencodeArgs(for: output, qscale: ffmpeg.videoToolboxQScale), output: output,
                             duration: info.duration / factor, progress: progress)
    }

    /// Crops to `rect`, in display pixels with the origin at the top left.
    public static func crop(_ src: URL, rect: CGRect, to output: URL, ffmpeg: FFmpeg, progress: @escaping Progress) async throws {
        let info = try await probe(src, ffmpeg: ffmpeg)
        guard let size = info.videoSize else { throw OrbitError.unsupported("There is no video in this file.") }
        let area = rect.standardized.intersection(CGRect(origin: .zero, size: size))
        let width = Int(VideoTools.evenFloor(area.width)), height = Int(VideoTools.evenFloor(area.height))
        guard !area.isNull, width >= 2, height >= 2 else { throw OrbitError.unsupported("The crop area is outside this video.") }
        let x = min(Int(area.minX.rounded()), Int(size.width) - width), y = min(Int(area.minY.rounded()), Int(size.height) - height)
        try await ffmpeg.run(inputs: [src], args: ["-vf", "crop=\(width):\(height):\(x):\(y)"] + reencodeArgs(for: output, qscale: ffmpeg.videoToolboxQScale),
                             output: output, duration: info.duration, progress: progress)
    }

    public static func snapshot(_ src: URL, at time: Double, to output: URL, ffmpeg: FFmpeg) async throws {
        let duration = try await ffmpeg.duration(of: src)
        // A time past the last frame makes ffmpeg write nothing and still exit 0.
        let seconds = min(max(time, 0), max(duration - 0.1, 0))
        try await ffmpeg.run(inputs: [src], args: ["-ss", number(seconds), "-frames:v", "1"], output: output,
                             duration: nil, progress: { _ in })
        guard VideoTools.fileSize(output) > 0 else { throw OrbitError.unsupported("Couldn't get a picture at that time.") }
    }

    // MARK: Join

    /// Joins the videos end to end. Clips of the same size are copied with the concat demuxer (a temporary
    /// list file); otherwise, or when the copy fails, they are re-encoded at the first clip's size.
    public static func join(_ srcs: [URL], to output: URL, ffmpeg: FFmpeg, scratch: () throws -> URL,
                            progress: @escaping Progress) async throws {
        guard srcs.count > 1 else { throw OrbitError.unsupported("Choose at least two videos to join.") }
        var probes: [Probe] = []
        for src in srcs {
            try Task.checkCancellation()
            probes.append(try await probe(src, ffmpeg: ffmpeg))
        }
        guard let size = probes[0].videoSize else { throw OrbitError.unsupported("There is no video in this file.") }
        let total = probes.reduce(0) { $0 + $1.duration }
        // The concat demuxer doesn't check codecs: clips whose streams differ in any way that matters
        // (codec, profile, pixel format, size, frame rate, rotation, audio format) are re-encoded.
        let copyable = probes.allSatisfy { $0.videoSize == size && $0.hasAudio == probes[0].hasAudio && $0.streams == probes[0].streams }

        if copyable {
            let list = try scratch().appending(path: "list.txt", directoryHint: .notDirectory)
            try listing(srcs).write(to: list, atomically: false, encoding: .utf8)
            do {
                try await ffmpeg.run(inputs: [], args: ["-f", "concat", "-safe", "0", "-i", FFmpeg.pathArg(list), "-c", "copy"],
                                     output: output, duration: total, progress: progress)
                return
            } catch let error where !(error is CancellationError) && (error as? OrbitError) != .cancelled
                        && !FFmpeg.isExistingOutputRefusal(error) {
                Log.info("Joining by stream copy failed, re-encoding: \(error)")
                try? FileManager.default.removeItem(at: output)
            }
        }

        // Re-encode: every clip is fitted inside the first clip's size (padded with black) and the audio is kept
        // when every clip has some.
        let w = Int(size.width) & ~1, h = Int(size.height) & ~1
        let withAudio = probes.allSatisfy(\.hasAudio)
        var chains: [String] = []
        for index in srcs.indices {
            chains.append("[\(index):v]scale=\(w):\(h):force_original_aspect_ratio=decrease,pad=\(w):\(h):(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(index)]")
            if withAudio { chains.append("[\(index):a]aresample=44100,aformat=sample_fmts=fltp:channel_layouts=stereo[a\(index)]") }
        }
        let pads = srcs.indices.map { withAudio ? "[v\($0)][a\($0)]" : "[v\($0)]" }.joined()
        let concat = "\(pads)concat=n=\(srcs.count):v=1:a=\(withAudio ? 1 : 0)[v]\(withAudio ? "[a]" : "")"
        var args = ["-filter_complex", (chains + [concat]).joined(separator: ";"), "-map", "[v]"]
        if withAudio { args += ["-map", "[a]"] }
        try await ffmpeg.run(inputs: srcs, args: args + reencodeArgs(for: output, qscale: ffmpeg.videoToolboxQScale),
                             output: output, duration: total, progress: progress)
    }

    /// The concat demuxer's list file: one `file '<path>'` line per clip.
    static func listing(_ srcs: [URL]) throws -> String {
        try srcs.map { src in
            guard !src.path.contains("\n"), !src.path.contains("\r") else {
                throw OrbitError.unsupported("Orbit can't join a file with a line break in its name.")
            }
            return "file '" + src.path.replacingOccurrences(of: "'", with: "'\\''") + "'\n"
        }.joined()
    }

    // MARK: Compress

    /// Re-encodes the video to fit under `target` (see `VideoTools.compress`) and returns the size written.
    public static func compress(_ src: URL, target: CompressTarget, to output: URL, ffmpeg: FFmpeg,
                                progress: @escaping Progress) async throws -> Int64 {
        let info = try await probe(src, ffmpeg: ffmpeg)
        let targetBytes = VideoTools.targetBytes(target, source: src)
        let height = Int(info.videoSize?.height ?? 0)
        return try await VideoTools.fit(under: targetBytes, duration: info.duration, sourceHeight: height,
                                        hasAudio: info.hasAudio, output: output, progress: progress) { plan, progress in
            var args = ["-b:v", "\(plan.videoKbps)k", "-maxrate", "\(plan.videoKbps)k", "-bufsize", "\(plan.videoKbps * 2)k"]
            if let maxHeight = plan.maxHeight { args += ["-vf", "scale=-2:\(maxHeight)"] }
            args += codecArgs(for: output, audioKbps: info.hasAudio ? plan.audioKbps : nil)
            try await ffmpeg.run(inputs: [src], args: args, output: output, duration: info.duration, progress: progress)
        }
    }

    // MARK: Arguments

    /// `-map 0`: every stream is kept (ffmpeg's default picks one video, one audio and one subtitle
    /// stream, dropping other language tracks and attachments). Data streams can't always be muxed.
    private static func trimArgs(_ start: Double, _ end: Double) -> [String] {
        ["-ss", number(start), "-to", number(end), "-map", "0", "-dn", "-c", "copy"]
    }

    /// `atempo` only takes 0.5 to 2 reliably, so other factors are chained: 4 is 2 then 2, 0.25 is 0.5 then 0.5.
    static func atempoChain(_ factor: Double) -> [String] {
        var chain: [String] = []
        var rest = factor
        while rest > 2 { chain.append("atempo=2"); rest /= 2 }
        while rest < 0.5 { chain.append("atempo=0.5"); rest /= 0.5 }
        if rest != 1 || chain.isEmpty { chain.append("atempo=\(number(rest))") }
        return chain
    }

    /// Codecs for a re-encode into the output's container: the format's own recipe (MKV, whose recipe is a
    /// stream copy, gets h264/aac).
    static func reencodeArgs(for output: URL, qscale: Bool = true) -> [String] {
        let ext = output.pathExtension.lowercased()
        if ext == "mkv" { return FFmpegRecipes.mkvFallback(qscale: qscale) }
        let format = ext == "m4v" ? OutputFormat.mp4 : (OutputFormat(rawValue: ext) ?? .mp4)
        let args = FFmpegRecipes.args(for: format, qscale: qscale)
        return args.isEmpty || args == ["-c", "copy"] ? FFmpegRecipes.args(for: .mp4, qscale: qscale) : args
    }

    /// Codecs for a bitrate-targeted encode into the output's container; `audioKbps` nil means no audio stream.
    static func codecArgs(for output: URL, audioKbps: Int?) -> [String] {
        var video: [String], audio: [String], container: [String] = []
        switch output.pathExtension.lowercased() {
        case "webm":
            video = ["-c:v", "libvpx-vp9", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4"]; audio = ["-c:a", "libopus"]
        case "avi":
            video = ["-c:v", "mpeg4"]; audio = ["-c:a", "libmp3lame"]
        case "wmv":
            video = ["-c:v", "wmv2"]; audio = ["-c:a", "wmav2"]
        case "mp4", "m4v":
            video = ["-c:v", "h264_videotoolbox"]; audio = ["-c:a", "aac"]; container = ["-movflags", "+faststart"]
        default: // mov, mkv
            video = ["-c:v", "h264_videotoolbox"]; audio = ["-c:a", "aac"]
        }
        if let audioKbps { audio += ["-b:a", "\(audioKbps)k"] }
        return video + (audioKbps == nil ? [] : audio) + container
    }

    /// A number for an ffmpeg argument: plain decimal, no exponent, no trailing zeros.
    static func number(_ value: Double) -> String {
        var text = String(format: "%.3f", value)
        while text.contains("."), text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
