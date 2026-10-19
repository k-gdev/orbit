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
        if usesNativePath(src, to: format) {
            try await convertNatively(src.url, to: format, output: output, progress: progress)
        } else {
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            try await convertWithFFmpeg(src.url, to: format, output: output, ffmpeg: ffmpeg, progress: progress)
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
        let duration = try? await ffmpeg.duration(of: url)
        do {
            try await ffmpeg.run(inputs: [url], args: FFmpegRecipes.args(for: format), output: output,
                                 duration: duration, progress: progress)
        } catch where format == .mkv && !isCancellation(error) {
            // A stream copy can't carry every codec into MKV: retry once, re-encoding as MP4 would.
            Log.info("ffmpeg stream copy to mkv failed, retrying with h264/aac")
            try? FileManager.default.removeItem(at: output)
            try await ffmpeg.run(inputs: [url], args: FFmpegRecipes.mkvFallback, output: output,
                                 duration: duration, progress: progress)
        }
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? OrbitError) == .cancelled
    }
}
