import AVFoundation
import CoreVideo
import Foundation

/// One H.264/AAC encode of a video with `AVAssetReader` and `AVAssetWriter`, at the bitrates (and height)
/// of a `VideoBitratePlan`. Frames come out upright, so the writer carries no transform.
final class VideoTranscoder: @unchecked Sendable {
    private let reader: AVAssetReader
    private let writer: AVAssetWriter
    private let queue = DispatchQueue(label: "com.kevo.orbit.video-transcode")
    private let lock = NSLock()
    private var cancelled = false
    private var pumps: [Pump] = []
    private let totalSeconds: Double
    private let progress: VideoTools.Progress

    private final class Pump: @unchecked Sendable {
        let output: AVAssetReaderOutput
        let input: AVAssetWriterInput
        let tracksProgress: Bool
        /// Only touched on the pump queue.
        var finished = false

        init(output: AVAssetReaderOutput, input: AVAssetWriterInput, tracksProgress: Bool) {
            self.output = output
            self.input = input
            self.tracksProgress = tracksProgress
        }

        func finish(_ group: DispatchGroup) {
            guard !finished else { return }
            finished = true
            input.markAsFinished()
            group.leave()
        }
    }

    static func encode(_ asset: AVAsset, info: VideoTrackInfo, plan: VideoBitratePlan, to output: URL,
                       progress: @escaping VideoTools.Progress) async throws {
        let transcoder = try await VideoTranscoder(asset, info: info, plan: plan, output: output, progress: progress)
        try await transcoder.run()
    }

    private init(_ asset: AVAsset, info: VideoTrackInfo, plan: VideoBitratePlan, output: URL,
                 progress: @escaping VideoTools.Progress) async throws {
        reader = try AVAssetReader(asset: asset)
        writer = try AVAssetWriter(outputURL: output, fileType: VideoTools.fileType(for: output))
        totalSeconds = max(info.duration.seconds, 0.001)
        self.progress = progress

        // Video: scaled to the plan's height, with the preferred transform applied by the reader.
        var size = info.displaySize
        if let maxHeight = plan.maxHeight, CGFloat(maxHeight) < size.height {
            let scale = CGFloat(maxHeight) / size.height
            size = CGSize(width: size.width * scale, height: CGFloat(maxHeight))
        }
        size = CGSize(width: max(VideoTools.evenFloor(size.width), 2), height: max(VideoTools.evenFloor(size.height), 2))
        let scale = CGAffineTransform(scaleX: size.width / info.displaySize.width, y: size.height / info.displaySize.height)
        let composition = VideoTools.videoComposition(info, transform: info.renderTransform.concatenating(scale), renderSize: size)

        let videoOutput = AVAssetReaderVideoCompositionOutput(videoTracks: [info.track], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        videoOutput.videoComposition = composition
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw OrbitError.unsupported("Orbit can't read this video.") }
        reader.add(videoOutput)

        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: plan.videoKbps * 1000,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoInput) else { throw OrbitError.unsupported("Orbit can't write this video.") }
        writer.add(videoInput)
        pumps.append(Pump(output: videoOutput, input: videoInput, tracksProgress: true))

        // Audio: AAC at the planned bitrate, mono or stereo.
        if plan.audioKbps > 0, let track = try await asset.loadTracks(withMediaType: .audio).first {
            let channels = try await Self.channelCount(of: track)
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
            ])
            audioOutput.alwaysCopiesSampleData = false
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 44100,
                AVNumberOfChannelsKey: channels,
                AVEncoderBitRateKey: plan.audioKbps * 1000,
            ])
            audioInput.expectsMediaDataInRealTime = false
            if reader.canAdd(audioOutput), writer.canAdd(audioInput) {
                reader.add(audioOutput)
                writer.add(audioInput)
                pumps.append(Pump(output: audioOutput, input: audioInput, tracksProgress: false))
            }
        }
    }

    private static func channelCount(of track: AVAssetTrack) async throws -> Int {
        for description in try await track.load(.formatDescriptions) {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee, asbd.mChannelsPerFrame > 0 {
                return min(Int(asbd.mChannelsPerFrame), 2)
            }
        }
        return 2
    }

    private func run() async throws {
        try Task.checkCancellation()
        guard reader.startReading() else { throw failure(reader.error, "AVAssetReader") }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw failure(writer.error, "AVAssetWriter")
        }
        writer.startSession(atSourceTime: .zero)

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let group = DispatchGroup()
                for pump in pumps {
                    group.enter()
                    pump.input.requestMediaDataWhenReady(on: queue) { [self] in
                        while pump.input.isReadyForMoreMediaData, !pump.finished {
                            if isCancelled || writer.status == .failed {
                                pump.finish(group)
                                return
                            }
                            guard let sample = pump.output.copyNextSampleBuffer() else {
                                pump.finish(group)
                                return
                            }
                            if pump.tracksProgress {
                                let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                                progress(min(max(time / totalSeconds, 0), 1))
                            }
                            if !pump.input.append(sample) {
                                pump.finish(group)
                                return
                            }
                        }
                    }
                }
                group.notify(queue: queue) { [self] in
                    if isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: CancellationError())
                    } else if reader.status == .failed {
                        writer.cancelWriting()
                        continuation.resume(throwing: failure(reader.error, "AVAssetReader"))
                    } else if writer.status == .failed {
                        reader.cancelReading()
                        continuation.resume(throwing: failure(writer.error, "AVAssetWriter"))
                    } else {
                        writer.finishWriting { [self] in
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: failure(writer.error, "AVAssetWriter"))
                            }
                        }
                    }
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Stops the pumps at the next sample; the pump queue then tears the reader and writer down.
    private func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        reader.cancelReading()
    }

    private func failure(_ error: Error?, _ tool: String) -> OrbitError {
        let message = error.map { String(describing: $0) } ?? "unknown error"
        Log.error("\(tool) failed: \(message)")
        return .processFailed(tool: tool, code: 1, stderr: message)
    }
}
