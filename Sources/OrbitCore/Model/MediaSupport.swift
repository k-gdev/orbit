import AVFoundation
import Foundation

public enum MediaSupport {
    public static let ffmpegOnlyRead: Set<String> = ["mkv", "webm", "avi", "wmv", "wma"]
    public static let nativeVideoWrite: Set<OutputFormat> = [.mp4, .mov]
    public static let nativeAudioWrite: Set<OutputFormat> = [.m4a, .aac, .wav, .aiff, .flac]

    /// True when AVFoundation can't read this item, so ffmpeg is required.
    public static func needsFFmpegToRead(_ item: DroppedItem) -> Bool {
        if ffmpegOnlyRead.contains(item.formatKey) { return true }
        guard item.category == .video || item.category == .audio else { return false }
        let supported = AVURLAsset.audiovisualTypes()
        return !supported.contains(AVFileType(rawValue: item.type.identifier))
    }

    /// True when the format can be written without ffmpeg (video/audio tool gating).
    public static func isNativelyWritable(formatKey: String) -> Bool {
        if formatKey == "m4v" { return true }
        guard let format = OutputFormat(rawValue: formatKey) else { return false }
        return nativeVideoWrite.contains(format) || nativeAudioWrite.contains(format)
    }
}
