import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The video tools, done natively with AVFoundation: trim, crop, speed, split, snapshot, mute, remove
/// metadata, join and compress. They run on sources AVFoundation can read and write the source's own
/// container (mp4, m4v or mov). `VideoToolsFFmpeg` covers everything else.
public enum VideoTools {
    public typealias Progress = @Sendable (Double) -> Void

    /// Speeds outside this range drop the audio (a stretched or squeezed track sounds wrong).
    static let audioSpeedRange: ClosedRange<Double> = 0.5...2
    /// The most a compress retries after the first encode came out too big.
    static let maximumRetries = 2
    /// A retry that needs its bitrate cut below this share also scales the picture down (by the square root of the share).
    static let shrinkBelowRatio = 0.7
    static let minimumShrunkHeight = 120

    // MARK: Trim, split

    /// Keeps `range` (seconds), clamped to the video. The cut lands on the nearest earlier keyframe.
    public static func trim(_ src: URL, range: ClosedRange<Double>, to output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        let timeRange = try clamp(range.lowerBound, range.upperBound, duration: duration)
        try await export(asset, to: output, timeRange: timeRange, passthrough: true, progress: progress)
    }

    /// Cuts the video at `points` (seconds); `outputs.count` must be `points.count + 1`.
    public static func split(_ src: URL, at points: [Double], to outputs: [URL], progress: @escaping Progress) async throws {
        guard outputs.count == points.count + 1 else {
            throw OrbitError.unsupported("Choose where to split first.")
        }
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard !points.isEmpty, zip(points, points.dropFirst()).allSatisfy({ $0 < $1 }),
              points[0] > 0, points[points.count - 1] < duration else {
            throw OrbitError.unsupported("The split points must be in order and inside the video.")
        }
        let edges = [0] + points + [duration]
        let count = Double(outputs.count)
        for (index, output) in outputs.enumerated() {
            try Task.checkCancellation()
            let timeRange = try clamp(edges[index], edges[index + 1], duration: duration)
            let base = Double(index)
            try await export(asset, to: output, timeRange: timeRange, passthrough: true,
                             progress: { progress((base + $0) / count) })
        }
        progress(1)
    }

    // MARK: Crop

    /// Crops to `rect`, in display pixels with the origin at the top left (after the video's `preferredTransform`).
    public static func crop(_ src: URL, rect: CGRect, to output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: src)
        let info = try await VideoTrackInfo.load(asset)
        let bounds = CGRect(origin: .zero, size: info.displaySize)
        let area = rect.standardized.intersection(bounds)
        let size = CGSize(width: evenFloor(area.width), height: evenFloor(area.height))
        guard !area.isNull, size.width >= 2, size.height >= 2 else {
            throw OrbitError.unsupported("The crop area is outside this video.")
        }
        let origin = CGPoint(x: min(area.minX.rounded(), info.displaySize.width - size.width),
                             y: min(area.minY.rounded(), info.displaySize.height - size.height))
        let transform = info.renderTransform.concatenating(CGAffineTransform(translationX: -origin.x, y: -origin.y))
        let composition = videoComposition(info, transform: transform, renderSize: size)
        try await export(asset, to: output, videoComposition: composition, passthrough: false, progress: progress)
    }

    // MARK: Speed

    /// Plays the video `factor` times as fast. Audio is kept (pitch-corrected) from half to double speed and dropped outside that.
    public static func speed(_ src: URL, factor: Double, to output: URL, progress: @escaping Progress) async throws {
        guard factor.isFinite, factor > 0 else { throw OrbitError.unsupported("Choose a speed first.") }
        let asset = AVURLAsset(url: src)
        let info = try await VideoTrackInfo.load(asset)
        let keepsAudio = audioSpeedRange.contains(factor)

        let composition = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: info.duration)
        let video = try composition.insert(info.track, range: range)
        video.preferredTransform = info.transform
        var mix: AVMutableAudioMix?
        if keepsAudio, let source = try await asset.loadTracks(withMediaType: .audio).first {
            let audio = try composition.insert(source, range: range)
            let parameters = AVMutableAudioMixInputParameters(track: audio)
            parameters.audioTimePitchAlgorithm = .spectral
            let audioMix = AVMutableAudioMix()
            audioMix.inputParameters = [parameters]
            mix = audioMix
        }
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: composition.duration),
                                   toDuration: CMTimeMultiplyByFloat64(composition.duration, multiplier: 1 / factor))
        try await export(composition, to: output, audioMix: mix, passthrough: false, progress: progress)
    }

    // MARK: Snapshot

    /// Saves the frame at `time` (seconds, clamped to the video) as a PNG, upright and at full size.
    public static func snapshot(_ src: URL, at time: Double, to output: URL) async throws {
        let asset = AVURLAsset(url: src)
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw OrbitError.unsupported("Orbit can't read this video.") }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        var seconds = max(time, 0)
        if seconds >= duration { seconds = max(duration - 0.05, 0) }
        let image: CGImage
        do {
            image = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 6000)).image
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.error("Snapshot failed: \(error)")
            throw OrbitError.processFailed(tool: "AVAssetImageGenerator", code: 1, stderr: String(describing: error))
        }
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw OrbitError.unsupported("Orbit can't save a picture here.")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw OrbitError.unsupported("Orbit can't save a picture here.")
        }
    }

    // MARK: Mute, remove metadata

    /// Copies the video without its audio tracks.
    public static func mute(_ src: URL, to output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: src)
        let info = try await VideoTrackInfo.load(asset)
        let composition = AVMutableComposition()
        let video = try composition.insert(info.track, range: CMTimeRange(start: .zero, duration: info.duration))
        video.preferredTransform = info.transform
        try await export(composition, to: output, passthrough: true, progress: progress)
    }

    /// Copies the video and audio without the file's metadata (camera, date, location, tags). The streams are
    /// copied into a fresh composition, which carries none of the source's file-level metadata.
    public static func removeMetadata(_ src: URL, to output: URL, progress: @escaping Progress) async throws {
        let asset = AVURLAsset(url: src)
        let composition = AVMutableComposition()
        for source in try await asset.loadTracks(withMediaType: .video) + asset.loadTracks(withMediaType: .audio) {
            let (range, transform) = try await source.load(.timeRange, .preferredTransform)
            let track = try composition.insert(source, range: range, at: range.start)
            if source.mediaType == .video { track.preferredTransform = transform }
        }
        guard !composition.tracks.isEmpty else { throw OrbitError.unsupported("There is no video in this file.") }
        try await export(composition, to: output, metadata: [], metadataItemFilter: .forSharing(), passthrough: true,
                         progress: progress)
    }

    // MARK: Join

    /// Joins the videos end to end. When every clip has the same size and orientation the streams are copied;
    /// otherwise the result is re-encoded at the first clip's size, with the others fitted inside it.
    public static func join(_ srcs: [URL], to output: URL, progress: @escaping Progress) async throws {
        guard srcs.count > 1 else { throw OrbitError.unsupported("Choose at least two videos to join.") }
        let composition = AVMutableComposition()
        var video: AVMutableCompositionTrack?
        var audio: AVMutableCompositionTrack?
        var clips: [(info: VideoTrackInfo, start: CMTime)] = []
        var cursor = CMTime.zero
        for src in srcs {
            try Task.checkCancellation()
            let asset = AVURLAsset(url: src)
            let info = try await VideoTrackInfo.load(asset)
            let range = CMTimeRange(start: .zero, duration: info.duration)
            if video == nil {
                video = try composition.insert(info.track, range: range, at: cursor)
            } else {
                try video?.insertTimeRange(range, of: info.track, at: cursor)
            }
            if let source = try await asset.loadTracks(withMediaType: .audio).first {
                let available = try await source.load(.timeRange)
                let part = CMTimeRange(start: available.start, duration: CMTimeMinimum(available.duration, info.duration))
                if audio == nil {
                    audio = try composition.insert(source, range: part, at: cursor)
                } else {
                    try audio?.insertTimeRange(part, of: source, at: cursor)
                }
            }
            clips.append((info, cursor))
            cursor = CMTimeAdd(cursor, info.duration)
        }
        guard let first = clips.first?.info else { return }
        let sameLayout = clips.allSatisfy { $0.info.displaySize == first.displaySize && $0.info.transform == first.transform }

        if sameLayout {
            video?.preferredTransform = first.transform
            do {
                try await export(composition, to: output, passthrough: true, reencodeOnFailure: false, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The clips' codecs didn't match after all: fall through and re-encode them together.
                Log.info("Joining by stream copy failed, re-encoding: \(error)")
                try? FileManager.default.removeItem(at: output)
            }
        }

        let renderSize = first.displaySize
        let instructions = clips.map { clip -> AVMutableVideoCompositionInstruction in
            let size = clip.info.displaySize
            let scale = min(renderSize.width / size.width, renderSize.height / size.height)
            let fitted = CGSize(width: size.width * scale, height: size.height * scale)
            let transform = clip.info.renderTransform
                .concatenating(CGAffineTransform(scaleX: scale, y: scale))
                .concatenating(CGAffineTransform(translationX: (renderSize.width - fitted.width) / 2,
                                                 y: (renderSize.height - fitted.height) / 2))
            let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video!)
            layer.setTransform(transform, at: clip.start)
            let instruction = AVMutableVideoCompositionInstruction()
            instruction.timeRange = CMTimeRange(start: clip.start, duration: clip.info.duration)
            instruction.layerInstructions = [layer]
            return instruction
        }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.instructions = instructions
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = clips.map(\.info.frameDuration).min { $0.seconds < $1.seconds } ?? first.frameDuration
        try await export(composition, to: output, videoComposition: videoComposition, passthrough: false, progress: progress)
    }

    // MARK: Compress

    /// Re-encodes the video (H.264, AAC) to fit under `target` and returns the size written. A tier target
    /// is a fraction of the source's size. Throws `.targetTooSmall` (and writes nothing) when it can't.
    public static func compress(_ src: URL, target: CompressTarget, to output: URL,
                                progress: @escaping Progress) async throws -> Int64 {
        let asset = AVURLAsset(url: src)
        let info = try await VideoTrackInfo.load(asset)
        let hasAudio = try await !asset.loadTracks(withMediaType: .audio).isEmpty
        let targetBytes = self.targetBytes(target, source: src)
        return try await fit(under: targetBytes, duration: info.duration.seconds, sourceHeight: Int(info.displaySize.height),
                             hasAudio: hasAudio, output: output, progress: progress) { plan, progress in
            try await VideoTranscoder.encode(asset, info: info, plan: plan, to: output, progress: progress)
        }
    }

    /// The byte target for a compress request.
    static func targetBytes(_ target: CompressTarget, source: URL) -> Int64 {
        switch target {
        case .fitUnder(let bytes):
            return bytes
        case .tier(let tier):
            return Int64(Double(fileSize(source)) * tier.targetFraction)
        }
    }

    /// Plans the bitrates for `targetBytes` and calls `encode` until the file at `output` fits (at most
    /// `maximumRetries` more times, each with a bitrate scaled by target / actual × 0.95). A file that is
    /// too big is never left behind. Returns the size of the file that fits.
    static func fit(under targetBytes: Int64, duration: Double, sourceHeight: Int, hasAudio: Bool, output: URL,
                    progress: @escaping Progress,
                    encode: (VideoBitratePlan, @escaping Progress) async throws -> Void) async throws -> Int64 {
        guard var plan = VideoBitrate.plan(durationSeconds: duration, targetBytes: targetBytes,
                                           sourceHeight: sourceHeight, hasAudio: hasAudio) else {
            throw tooSmall(targetBytes)
        }
        // The first encode gets most of the bar; retries share the rest.
        let spans: [(start: Double, end: Double)] = [(0, 0.7), (0.7, 0.85), (0.85, 1)]
        var height = plan.maxHeight ?? sourceHeight
        for attempt in 0...maximumRetries {
            try Task.checkCancellation()
            let span = spans[attempt]
            try await encode(plan, { progress(span.start + $0 * (span.end - span.start)) })
            let actual = fileSize(output)
            if actual <= targetBytes {
                progress(1)
                return actual
            }
            try? FileManager.default.removeItem(at: output)
            let ratio = Double(targetBytes) / Double(actual) * 0.95
            let scaled = Int(Double(plan.videoKbps) * ratio)
            guard attempt < maximumRetries, scaled >= VideoBitrate.minimumVideoKbps else { break }
            plan.videoKbps = scaled
            if ratio < shrinkBelowRatio {
                // Far over the bitrate it was given (noisy footage that encoders can't squeeze): a smaller
                // picture is the only thing left that brings the size down.
                let smaller = Int(evenFloor(CGFloat(height) * CGFloat(ratio.squareRoot())))
                guard smaller >= minimumShrunkHeight else { break }
                height = smaller
                plan.maxHeight = smaller
            }
        }
        throw tooSmall(targetBytes)
    }

    static func tooSmall(_ bytes: Int64) -> OrbitError {
        .targetTooSmall("Can't fit this video under \(ResultSummary.bytes(bytes)).")
    }

    /// The size on disk. (Not `URL.resourceValues`, which caches the size on the URL: the compress loop
    /// rewrites the same URL.)
    static func fileSize(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: Shared

    static func fileType(for output: URL) -> AVFileType {
        switch output.pathExtension.lowercased() {
        case "mp4": .mp4
        case "m4v": .m4v
        default: .mov
        }
    }

    /// Rounds down to an even number of pixels (video encoders want even sizes).
    static func evenFloor(_ value: CGFloat) -> CGFloat {
        CGFloat(max(Int(value.rounded(.down)) & ~1, 0))
    }

    private static func clamp(_ lower: Double, _ upper: Double, duration: Double) throws -> CMTimeRange {
        let start = max(lower, 0), end = min(upper, duration)
        guard duration.isFinite, end - start >= 0.01 else {
            throw OrbitError.unsupported("The part to keep is outside this video.")
        }
        return CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 6000),
                           end: CMTime(seconds: end, preferredTimescale: 6000))
    }

    /// One instruction covering the whole asset. `transform` must be a render transform (see `VideoTrackInfo.renderTransform`).
    static func videoComposition(_ info: VideoTrackInfo, transform: CGAffineTransform, renderSize: CGSize) -> AVMutableVideoComposition {
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: info.track)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        // The whole asset, not just the video track: an export fails when the audio runs past the instructions.
        instruction.timeRange = CMTimeRange(start: .zero, duration: info.assetDuration)
        instruction.layerInstructions = [layer]
        let composition = AVMutableVideoComposition()
        composition.instructions = [instruction]
        composition.renderSize = renderSize
        composition.frameDuration = info.frameDuration
        return composition
    }

    /// Exports `asset` to `output`. A stream copy is tried first when `passthrough` is set and the asset
    /// allows it; if that fails (or isn't possible) the video is re-encoded, unless `reencodeOnFailure` is off.
    static func export(_ asset: AVAsset, to output: URL, timeRange: CMTimeRange? = nil,
                       videoComposition: AVVideoComposition? = nil, audioMix: AVAudioMix? = nil,
                       metadata: [AVMetadataItem]? = nil, metadataItemFilter: AVMetadataItemFilter? = nil,
                       passthrough: Bool, reencodeOnFailure: Bool = true,
                       progress: @escaping Progress) async throws {
        let type = fileType(for: output)
        if passthrough,
           await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset,
                                                    outputFileType: type) {
            do {
                try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, fileType: type, to: output,
                                             videoComposition: videoComposition, audioMix: audioMix, timeRange: timeRange,
                                             metadata: metadata, metadataItemFilter: metadataItemFilter, progress: progress)
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch where reencodeOnFailure {
                Log.info("Stream copy to \(type.rawValue) failed, re-encoding: \(error)")
                try? FileManager.default.removeItem(at: output)
            }
        }
        if passthrough, !reencodeOnFailure { throw OrbitError.unsupported("Orbit can't copy these streams as they are.") }
        try await MediaExport.export(asset, preset: AVAssetExportPresetHighestQuality, fileType: type, to: output,
                                     videoComposition: videoComposition, audioMix: audioMix, timeRange: timeRange,
                                     metadata: metadata, metadataItemFilter: metadataItemFilter, progress: progress)
    }
}

/// What the tools need to know about a video's first video track.
struct VideoTrackInfo {
    let track: AVAssetTrack
    /// The track's `preferredTransform` as stored. Use it for `preferredTransform` on a copied track (stream copy).
    let transform: CGAffineTransform
    /// The transform that puts the upright picture at (0, 0): `transform` plus a translation by the origin of the
    /// transformed bounding box. The two differ when the stored matrix has no translation (`ffmpeg -display_rotation`
    /// writes tx = ty = 0). Use it in every layer instruction, which does not normalise the origin itself.
    let renderTransform: CGAffineTransform
    /// The size on screen, after `preferredTransform`.
    let displaySize: CGSize
    /// The track's length.
    let duration: CMTime
    /// The whole asset's length (the audio can run past the video).
    let assetDuration: CMTime
    let frameDuration: CMTime

    static func load(_ asset: AVAsset) async throws -> VideoTrackInfo {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw OrbitError.unsupported("There is no video in this file.")
        }
        let (size, transform, timeRange, rate) = try await track.load(.naturalSize, .preferredTransform, .timeRange, .nominalFrameRate)
        let assetDuration = try await asset.load(.duration)
        let box = CGRect(origin: .zero, size: size).applying(transform)
        let display = CGSize(width: abs(box.width).rounded(), height: abs(box.height).rounded())
        let fps = rate > 1 ? Int32(rate.rounded()) : 30
        return VideoTrackInfo(
            track: track, transform: transform,
            renderTransform: transform.concatenating(CGAffineTransform(translationX: -box.minX, y: -box.minY)),
            displaySize: display, duration: timeRange.duration,
            assetDuration: CMTimeMaximum(assetDuration.isNumeric ? assetDuration : timeRange.duration, timeRange.duration),
            frameDuration: CMTime(value: 1, timescale: fps))
    }
}

extension AVMutableComposition {
    /// Adds a track holding `range` of `source`, at `time`.
    @discardableResult
    func insert(_ source: AVAssetTrack, range: CMTimeRange, at time: CMTime = .zero) throws -> AVMutableCompositionTrack {
        guard let track = addMutableTrack(withMediaType: source.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw OrbitError.unsupported("Orbit can't edit this video.")
        }
        try track.insertTimeRange(range, of: source, at: time)
        return track
    }
}
