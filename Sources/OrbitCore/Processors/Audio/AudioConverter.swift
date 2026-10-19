import AVFoundation
import Foundation

/// Converts audio to another audio format. AVFoundation does what it can (a readable source and an
/// m4a, aac, wav, aiff or flac output); everything else goes through ffmpeg.
///
/// Also holds the streaming read/write helpers the audio tools share: audio is moved in chunks, so a
/// long recording is never held in memory whole.
public enum AudioConverter {
    /// Frames moved per read/write.
    static let chunkFrames: AVAudioFrameCount = 32_768
    /// The AAC bitrate of an m4a/aac conversion.
    static let aacKbps = 256

    public static func usesNativePath(_ item: DroppedItem, to format: OutputFormat) -> Bool {
        MediaSupport.nativeAudioWrite.contains(format) && !MediaSupport.needsFFmpegToRead(item)
    }

    public static func convert(_ src: DroppedItem, to format: OutputFormat, output: URL, ffmpeg: FFmpeg?,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        if usesNativePath(src, to: format), let input = try? AVAudioFile(forReading: src.url) {
            func encode(to url: URL, progress: (Double) -> Void) throws {
                let writer = try makeWriter(url, format: format, sampleRate: input.processingFormat.sampleRate,
                                            channels: Int(input.processingFormat.channelCount), kbps: aacKbps)
                try copy(from: input, to: writer, progress: progress)
            }
            if format == .m4a {
                try await encodeM4A(to: output, tags: await AudioMetadata.carriedTags(from: src.url), progress: progress,
                                    write: encode)
            } else {
                try encode(to: output, progress: progress)
            }
            progress(1)
            return
        }
        guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
        let duration = try? await ffmpeg.duration(of: src.url)
        try await ffmpeg.run(inputs: [src.url], args: FFmpegRecipes.args(for: format), output: output,
                             duration: duration, progress: progress)
    }

    // MARK: ffmpeg recipes

    /// The recipe for `format`, with its bitrate or quality setting replaced by `kbps` when given.
    static func recipe(for format: OutputFormat, kbps: Int? = nil) -> [String] {
        var args = FFmpegRecipes.args(for: format)
        guard let kbps else { return args }
        var index = 0
        while index < args.count {
            if args[index] == "-b:a" || args[index] == "-q:a", index + 1 < args.count {
                args.removeSubrange(index...(index + 1))
            } else {
                index += 1
            }
        }
        return args + ["-b:a", "\(kbps)k"]
    }

    // MARK: Native writing

    /// `AVAudioFile` settings for a native output: AAC for m4a/aac, 16-bit PCM for wav (little endian)
    /// and aiff (big endian), FLAC.
    static func settings(for format: OutputFormat, sampleRate: Double, channels: Int, kbps: Int,
                         variable: Bool = false) -> [String: Any]? {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch format {
        case .m4a, .aac:
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            // A constant rate makes the size predictable; "Smaller" lets the encoder average around its target.
            settings[AVEncoderBitRateStrategyKey] = variable ? AVAudioBitRateStrategy_LongTermAverage : AVAudioBitRateStrategy_Constant
            settings[AVEncoderBitRateKey] = clampedBitrate(kbps, sampleRate: sampleRate, channels: channels) * 1000
        case .wav:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = false
        case .aiff:
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 16
            settings[AVLinearPCMIsFloatKey] = false
            settings[AVLinearPCMIsBigEndianKey] = true
        case .flac:
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVLinearPCMBitDepthKey] = 16
        default:
            return nil
        }
        return settings
    }

    /// The AAC encoder only accepts some bitrates for a given sample rate and channel count: the one
    /// nearest to `kbps` that it accepts (or `kbps` itself when the encoder can't say).
    static func clampedBitrate(_ kbps: Int, sampleRate: Double, channels: Int) -> Int {
        guard let pcm = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false),
              let aac = AVAudioFormat(settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                                 AVNumberOfChannelsKey: channels]),
              let converter = AVAudioConverter(from: pcm, to: aac) else { return kbps }
        let allowed = (converter.applicableEncodeBitRates ?? []).map { $0.intValue / 1000 }.filter { $0 > 0 }
        return allowed.min { abs($0 - kbps) < abs($1 - kbps) } ?? kbps
    }

    /// A file that takes Float32 buffers and writes them in `format`.
    static func makeWriter(_ url: URL, format: OutputFormat, sampleRate: Double, channels: Int, kbps: Int,
                           variable: Bool = false) throws -> AVAudioFile {
        guard let settings = settings(for: format, sampleRate: sampleRate, channels: channels, kbps: kbps, variable: variable) else {
            throw OrbitError.unsupported("Orbit can't write \(format.label) here.")
        }
        return try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    /// Encodes an m4a in two steps. `AVAudioFile` leaves a large block of padding in an m4a, so the AAC
    /// is written to a scratch file (`write`) and then re-wrapped without re-encoding, which drops the
    /// padding and attaches `tags`.
    static func encodeM4A(to output: URL, tags: [AVMetadataItem]?, progress: @escaping @Sendable (Double) -> Void,
                          write: (_ scratch: URL, _ progress: (Double) -> Void) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "Orbit/audio-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let encoded = folder.appending(path: "encoded.m4a", directoryHint: .notDirectory)
        try write(encoded, { progress($0 * 0.9) })
        let asset = AVURLAsset(url: encoded)
        do {
            try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, fileType: .m4a, to: output,
                                         metadata: tags, progress: { progress(0.9 + $0 * 0.1) })
        } catch where !(error is CancellationError) && tags != nil {
            // The tags didn't fit the new file: keep the audio without them.
            Log.info("m4a export with tags failed, retrying without: \(error)")
            try? FileManager.default.removeItem(at: output)
            try await MediaExport.export(asset, preset: AVAssetExportPresetPassthrough, fileType: .m4a, to: output,
                                         progress: { progress(0.9 + $0 * 0.1) })
        }
    }

    // MARK: Streaming

    /// Moves frames from `input` to `output` chunk by chunk, `transform` getting each chunk and its
    /// first frame's position in the whole file. `frameCount` limits how many frames are read.
    /// Checks for cancellation between chunks.
    static func copy(from input: AVAudioFile, to output: AVAudioFile, startFrame: AVAudioFramePosition = 0,
                     frameCount: AVAudioFramePosition? = nil, progress: (Double) -> Void,
                     transform: (AVAudioPCMBuffer, AVAudioFramePosition) throws -> AVAudioPCMBuffer = { buffer, _ in buffer }) throws {
        let available = max(input.length - startFrame, 0)
        let total = min(frameCount ?? available, available)
        input.framePosition = startFrame
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else {
            throw OrbitError.unsupported("Orbit can't read this audio.")
        }
        var staging: AVAudioPCMBuffer?
        var done: AVAudioFramePosition = 0
        while done < total {
            try Task.checkCancellation()
            let want = AVAudioFrameCount(min(AVAudioFramePosition(chunkFrames), total - done))
            try input.read(into: buffer, frameCount: want)
            if buffer.frameLength == 0 { break }
            let processed = try transform(buffer, startFrame + done)
            try write(processed, to: output, staging: &staging)
            done += AVAudioFramePosition(buffer.frameLength)
            progress(Double(done) / Double(max(total, 1)))
        }
    }

    /// Reads the whole file through `meter` (loudness and peak), then leaves the read position at the start.
    static func measure(_ input: AVAudioFile, into meter: inout AudioDSP.Meter, progress: (Double) -> Void) throws {
        input.framePosition = 0
        guard let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: chunkFrames) else {
            throw OrbitError.unsupported("Orbit can't read this audio.")
        }
        let total = input.length
        while input.framePosition < total {
            try Task.checkCancellation()
            try input.read(into: buffer, frameCount: chunkFrames)
            if buffer.frameLength == 0 { break }
            meter.add(buffer)
            progress(Double(input.framePosition) / Double(max(total, 1)))
        }
        input.framePosition = 0
    }

    /// Writes a buffer through one in the writer's own processing format, which is what `AVAudioFile`
    /// insists on (the channel layout of a transformed buffer may differ).
    static func write(_ buffer: AVAudioPCMBuffer, to file: AVAudioFile, staging: inout AVAudioPCMBuffer?) throws {
        let format = file.processingFormat
        guard buffer.format.channelCount == format.channelCount,
              let source = buffer.floatChannelData else {
            throw OrbitError.unsupported("Orbit can't write this audio.")
        }
        if staging == nil || staging!.frameCapacity < buffer.frameLength {
            staging = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, chunkFrames))
        }
        guard let stage = staging, let target = stage.floatChannelData else {
            throw OrbitError.unsupported("Orbit can't write this audio.")
        }
        stage.frameLength = buffer.frameLength
        for c in 0..<Int(format.channelCount) {
            memcpy(target[c], source[c], Int(buffer.frameLength) * MemoryLayout<Float>.size)
        }
        try file.write(from: stage)
    }
}
