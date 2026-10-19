import CoreGraphics
import Foundation

/// What the video editors need to know about a file AVFoundation can't open (MKV, WebM, WMV and some AVI), read from the
/// stream listing that `ffmpeg -i file` prints.
public enum MediaProbe {
    public struct VideoStream: Equatable, Sendable {
        /// The size the picture is shown at: a quarter-turn display matrix swaps the stored width and height.
        public let displaySize: CGSize
        public let frameRate: Double?
    }

    /// The first video stream of `url`, or nil when ffmpeg lists none. Throws when ffmpeg can't be run or the probe is
    /// cancelled, so "couldn't ask" is never mistaken for "no video". (`ffmpeg -i` with no output exits non-zero by design.)
    public static func videoStream(of url: URL, ffmpeg: FFmpeg) async throws -> VideoStream? {
        let result = try await ProcessRunner.runCapturing(ffmpeg.executable, ["-hide_banner", "-i", FFmpeg.pathArg(url)])
        return parseVideoStream(result.stderr)
    }

    /// Reads the first `Video:` line of an ffmpeg stream listing, and the display-matrix rotation listed under it.
    public static func parseVideoStream(_ stderr: String) -> VideoStream? {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        guard let index = lines.firstIndex(where: { $0.contains("Stream #") && $0.contains("Video:") }),
              let size = firstMatch(#"\b(\d{2,5})x(\d{2,5})\b"#, in: lines[index]),
              let w = Double(size[0]), let h = Double(size[1]), w > 0, h > 0 else { return nil }
        let fps = firstMatch(#"(\d+(?:\.\d+)?) fps"#, in: lines[index]).flatMap { Double($0[0]) }

        // The side data of this stream sits on the lines before the next `Stream #`.
        var turned = false
        for line in lines[(index + 1)...] {
            if line.contains("Stream #") { break }
            if let angle = firstMatch(#"rotation of (-?\d+(?:\.\d+)?) degrees"#, in: line).flatMap({ Double($0[0]) }) {
                let quarter = Int((abs(angle) / 90).rounded())
                turned = quarter % 2 == 1
            }
        }
        return VideoStream(displaySize: turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h),
                           frameRate: fps.flatMap { $0 > 0 ? $0 : nil })
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = text as NSString
        guard let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { ns.substring(with: m.range(at: $0)) }
    }
}
