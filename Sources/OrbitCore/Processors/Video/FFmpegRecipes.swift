import CoreGraphics
import Foundation

/// The ffmpeg output arguments for each target format (everything between the inputs and the output path).
public enum FFmpegRecipes {
    /// `qscale`: whether h264_videotoolbox may use `-q:v`. FFmpeg only allows that when ffmpeg runs as
    /// arm64 (videotoolboxenc's `vtenc_qscale_enabled`); elsewhere `-q:v` fails, so a bitrate is used
    /// (see `FFmpeg.videoToolboxQScale`).
    public static func args(for output: OutputFormat, qscale: Bool = true) -> [String] {
        switch output {
        case .mp4: return h264(qscale) + split("-c:a aac -b:a 192k -movflags +faststart")
        case .mov: return h264(qscale) + split("-c:a aac -b:a 192k")
        case .mkv: return split("-c copy")
        case .webm: return split("-c:v libvpx-vp9 -b:v 0 -crf 32 -row-mt 1 -deadline good -cpu-used 4 -c:a libopus -b:a 128k")
        case .avi: return split("-c:v mpeg4 -q:v 3 -c:a libmp3lame -q:a 4")
        case .wmv: return split("-c:v wmv2 -b:v 4M -c:a wmav2 -b:a 192k")
        case .gif: return gif(fps: 12, size: nil, frames: nil)
        case .mp3: return split("-vn -c:a libmp3lame -q:a 2")
        case .m4a: return split("-vn -c:a aac -b:a 256k")
        case .aac: return split("-vn -c:a aac -b:a 256k -f adts")
        case .wav: return split("-vn -c:a pcm_s16le")
        case .aiff: return split("-vn -c:a pcm_s16be")
        case .flac: return split("-vn -c:a flac")
        case .ogg, .opus: return split("-vn -c:a libopus -b:a 160k")
        case .wma: return split("-vn -c:a wmav2 -b:a 192k")
        default: return []
        }
    }

    /// A GIF at `fps`, scaled to `size` (or at most 480 wide when nil), stopping after `frames` frames.
    /// The palette pass buffers every frame, so callers cap `frames` with `GIFMaker.plan`.
    static func gif(fps: Double, size: CGSize?, frames: Int?) -> [String] {
        let scale = size.map { "scale=\(Int($0.width)):\(Int($0.height)):flags=lanczos" }
            ?? "scale='min(480,iw)':-2:flags=lanczos"
        var args = ["-vf", "fps=\(VideoToolsFFmpeg.number(fps)),\(scale),split[a][b];[a]palettegen[p];[b][p]paletteuse"]
        if let frames { args += ["-frames:v", "\(frames)"] }
        return args + split("-loop 0")
    }

    /// The MP4 video and audio arguments, for retrying a failed stream copy into MKV.
    static func mkvFallback(qscale: Bool = true) -> [String] {
        h264(qscale) + split("-c:a aac -b:a 192k")
    }

    /// h264_videotoolbox at a constant quality, or (where ffmpeg can't do that) at an average bitrate.
    private static func h264(_ qscale: Bool) -> [String] {
        qscale ? split("-c:v h264_videotoolbox -q:v 65") : split("-c:v h264_videotoolbox -b:v 8M")
    }

    /// Splits on single spaces; no recipe argument contains a space.
    private static func split(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init)
    }
}
