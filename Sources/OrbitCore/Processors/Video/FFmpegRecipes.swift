import Foundation

/// The ffmpeg output arguments for each target format (everything between the inputs and the output path).
public enum FFmpegRecipes {
    public static func args(for output: OutputFormat) -> [String] {
        switch output {
        case .mp4: return split("-c:v h264_videotoolbox -q:v 65 -c:a aac -b:a 192k -movflags +faststart")
        case .mov: return split("-c:v h264_videotoolbox -q:v 65 -c:a aac -b:a 192k")
        case .mkv: return split("-c copy")
        case .webm: return split("-c:v libvpx-vp9 -b:v 0 -crf 32 -row-mt 1 -deadline good -cpu-used 4 -c:a libopus -b:a 128k")
        case .avi: return split("-c:v mpeg4 -q:v 3 -c:a libmp3lame -q:a 4")
        case .wmv: return split("-c:v wmv2 -b:v 4M -c:a wmav2 -b:a 192k")
        case .gif:
            return split("-vf") + ["fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
                + split("-loop 0")
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

    /// The MP4 video and audio arguments, for retrying a failed stream copy into MKV.
    static var mkvFallback: [String] {
        split("-c:v h264_videotoolbox -q:v 65 -c:a aac -b:a 192k")
    }

    /// Splits on single spaces; no recipe argument contains a space.
    private static func split(_ s: String) -> [String] {
        s.split(separator: " ").map(String.init)
    }
}
