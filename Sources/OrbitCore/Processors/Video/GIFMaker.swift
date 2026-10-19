import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a video as a looping GIF with `AVAssetImageGenerator` (exact frame times, orientation applied).
public enum GIFMaker {
    /// `CGImageDestination` keeps every frame in memory until finalize, so total decoded pixels are capped:
    /// at most 600 frames of 480x270 (about 300 MB of BGRA), however the frames are shaped.
    public static let maxFrames = 600
    public static let maxPixels = 600 * 480 * 270
    /// Below this frame rate a GIF is a slideshow; longer clips are rejected instead.
    public static let minFPS = 2.0

    /// Output frame size: the source scaled down (never up) so its longer side is at most `maxSide`.
    static func outputSize(for source: CGSize, maxSide: Int) -> CGSize {
        let scale = min(1, Double(maxSide) / max(source.width, source.height))
        return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
    }

    /// Most frames a clip with frames of `size` may render within the pixel budget (and `maxFrames`).
    static func frameBudget(for size: CGSize) -> Int {
        max(1, min(maxFrames, maxPixels / max(1, Int(size.width * size.height))))
    }

    /// Longest clip, in seconds, that still renders at `minFPS`.
    static func maxDuration(for size: CGSize) -> Double { Double(frameBudget(for: size)) / minFPS }

    /// Frame rate and count to render: fps is lowered so `count` fits the budget; nil when the clip is too long.
    static func plan(duration: Double, fps: Double, size: CGSize = CGSize(width: 480, height: 270)) -> (fps: Double, count: Int)? {
        let budget = frameBudget(for: size)
        let effective = min(fps, Double(budget) / duration)
        guard effective >= minFPS else { return nil }
        return (effective, min(budget, max(1, Int((duration * effective).rounded()))))
    }

    public static func make(_ src: URL, to output: URL, fps: Double = 12, maxWidth: Int = 480, // longest side of the GIF in pixels
                            
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, fps > 0 else {
            throw OrbitError.unsupported("Couldn't read \(src.lastPathComponent).")
        }
        let source = try await MediaInfo.videoSize(src) ?? CGSize(width: maxWidth, height: maxWidth)
        let size = outputSize(for: source, maxSide: maxWidth)
        guard let plan = plan(duration: duration, fps: fps, size: size) else {
            let minutes = max(1, Int(maxDuration(for: size) / 60))
            throw OrbitError.unsupported("\(src.lastPathComponent) is too long for a GIF (\(minutes) minutes at most).")
        }
        let fps = plan.fps
        let count = plan.count

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: maxWidth) // longer side <= maxWidth, so portrait clips stay small too

        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw OrbitError.unsupported("Orbit can't write a GIF here.")
        }
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        let frameProperties = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary

        // Keep the last frame inside the clip: asking for exactly `duration` can fail.
        let times = (0..<count).map { CMTime(seconds: min(Double($0) / fps, max(0, duration - 0.001)), preferredTimescale: 600) }
        var written = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            let image = try result.image
            CGImageDestinationAddImage(destination, image, frameProperties)
            written += 1
            progress(Double(written) / Double(count) * 0.95)
        }
        try Task.checkCancellation()
        guard written == count, CGImageDestinationFinalize(destination) else {
            throw OrbitError.unsupported("Couldn't make a GIF from \(src.lastPathComponent).")
        }
        progress(1)
    }
}
