import AVFoundation
import Foundation

/// Converts a video to another video format, a GIF, or an audio track. AVFoundation does what it can
/// (readable source, mp4/mov/gif/m4a output); everything else goes through ffmpeg.
public enum VideoConverter {
    private static let nativeOutputs: Set<OutputFormat> = [.mp4, .mov, .gif, .m4a]

    public static func usesNativePath(_ item: DroppedItem, to format: OutputFormat) -> Bool {
        !MediaSupport.needsFFmpegToRead(item) && nativeOutputs.contains(format)
    }

    public static func convert(_ src: DroppedItem, to format: OutputFormat, output: URL, ffmpeg: FFmpeg?,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        if audioOnlyOutputs.contains(format) {
            try await requireSound(in: src, ffmpeg: ffmpeg)
        }
        if usesNativePath(src, to: format) {
            try await convertNatively(src.url, to: format, output: output, progress: progress)
        } else {
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            try await convertWithFFmpeg(src.url, to: format, output: output, ffmpeg: ffmpeg, progress: progress)
        }
    }

    private static let audioOnlyOutputs: Set<OutputFormat> = [.mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus, .wma]

    /// Screen recordings and many exported clips have no audio track; extracting sound from them
    /// would otherwise fail with an opaque AVFoundation or ffmpeg error.
    private static func requireSound(in src: DroppedItem, ffmpeg: FFmpeg?) async throws {
        let hasSound: Bool
        if !MediaSupport.needsFFmpegToRead(src) {
            hasSound = try await MediaInfo.hasAudio(src.url)
        } else if let ffmpeg {
            hasSound = try await VideoToolsFFmpeg.probe(src.url, ffmpeg: ffmpeg).hasAudio
        } else {
            return  // the ffmpeg path reports the missing helper itself
        }
        if !hasSound {
            throw OrbitError.unsupported("\(src.url.lastPathComponent) has no sound to extract.")
        }
    }

    // MARK: Native

    private static func convertNatively(_ url: URL, to format: OutputFormat, output: URL,
                                        progress: @escaping @Sendable (Double) -> Void) async throws {
        switch format {
        case .gif:
            try await GIFMaker.make(url, to: output, progress: progress)
        case .m4a:
            try await MediaExport.export(AVURLAsset(url: url), preset: AVAssetExportPresetAppleM4A, fileType: .m4a,
                                         to: output, progress: progress)
        default:
            let fileType: AVFileType = format == .mp4 ? .mp4 : .mov
            let asset = AVURLAsset(url: url)
            if await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset,
                                                        outputFileType: fileType) {
                do {
                    try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, fileType: fileType,
                                                 to: output, progress: progress)
                    return
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The codecs didn't fit the container after all: re-encode instead.
                    Log.info("Passthrough to \(format.rawValue) failed, re-encoding: \(error)")
                    try? FileManager.default.removeItem(at: output)
                }
            }
            try await MediaExport.export(asset, preset: AVAssetExportPresetHighestQuality, fileType: fileType,
                                         to: output, progress: progress)
        }
    }

    // MARK: ffmpeg

    private static func convertWithFFmpeg(_ url: URL, to format: OutputFormat, output: URL, ffmpeg: FFmpeg,
                                          progress: @escaping @Sendable (Double) -> Void) async throws {
        if format == .gif {
            try await gifWithFFmpeg(url, output: output, ffmpeg: ffmpeg, progress: progress)
            return
        }
        let duration = try? await ffmpeg.duration(of: url)
        do {
            try await ffmpeg.run(inputs: [url], args: FFmpegRecipes.args(for: format, qscale: ffmpeg.videoToolboxQScale),
                                 output: output, duration: duration, progress: progress)
        } catch where format == .mkv && !isCancellation(error) && !FFmpeg.isExistingOutputRefusal(error) {
            // A stream copy can't carry every codec into MKV: retry once, re-encoding as MP4 would.
            Log.info("ffmpeg stream copy to mkv failed, retrying with h264/aac")
            try? FileManager.default.removeItem(at: output)
            try await ffmpeg.run(inputs: [url], args: FFmpegRecipes.mkvFallback(qscale: ffmpeg.videoToolboxQScale),
                                 output: output, duration: duration, progress: progress)
        }
    }

    /// The same frame budget as the native GIF path (`GIFMaker.plan`): ffmpeg's palette pass keeps
    /// every frame in memory, so a long clip is refused rather than swapping the Mac.
    private static func gifWithFFmpeg(_ url: URL, output: URL, ffmpeg: FFmpeg,
                                      progress: @escaping @Sendable (Double) -> Void) async throws {
        let info = try await VideoToolsFFmpeg.probe(url, ffmpeg: ffmpeg)
        let maxSide = 480
        let size = GIFMaker.outputSize(for: info.videoSize ?? CGSize(width: maxSide, height: maxSide), maxSide: maxSide)
        guard info.duration > 0, let plan = GIFMaker.plan(duration: info.duration, fps: 12, size: size) else {
            let minutes = max(1, Int(GIFMaker.maxDuration(for: size) / 60))
            throw OrbitError.unsupported("\(url.lastPathComponent) is too long for a GIF (\(minutes) minutes at most).")
        }
        try await ffmpeg.run(inputs: [url], args: FFmpegRecipes.gif(fps: plan.fps, size: size, frames: plan.count),
                             output: output, duration: info.duration, progress: progress)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? OrbitError) == .cancelled
    }
}
