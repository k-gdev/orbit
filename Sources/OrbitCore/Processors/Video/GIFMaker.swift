import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Renders a video as a looping GIF with `AVAssetImageGenerator` (exact frame times, orientation applied).
public enum GIFMaker {
    public static func make(_ src: URL, to output: URL, fps: Double = 12, maxWidth: Int = 480,
                            progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0, fps > 0 else {
            throw OrbitError.unsupported("Couldn't read \(src.lastPathComponent).")
        }
        let count = max(1, Int((duration * fps).rounded()))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxWidth, height: 100_000)

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
