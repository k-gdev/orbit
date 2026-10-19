import AVFoundation
import Foundation

/// The audio tools that change the sound: compress, trim, normalize, bleep and channels.
///
/// Every tool runs the same pipeline. The source is decoded natively when AVFoundation can read it
/// and by ffmpeg (to a temporary WAV) when it can't. The audio is processed chunk by chunk. The result
/// is written natively when the output format is natively writable; otherwise it goes to a temporary
/// WAV that ffmpeg encodes, copying the tags from the source (`-map_metadata 1`).
/// The output keeps the source's format, except that compressing a lossless file (wav, aiff, flac)
/// makes an m4a.
public enum AudioTools {
    /// How small a compressed file should be.
    public enum Rate: Equatable, Sendable {
        case kbps(Int)
        /// Half the source's bitrate, at least 64 kbps.
        case smaller
        /// Fit under this many bytes.
        case fitUnder(Int64)
    }

    public enum Operation: Equatable, Sendable {
        case compress(Rate)
        case trim(ClosedRange<Double>)
        case normalize
        case bleep([ClosedRange<Double>])
        case channels(ChannelOp)
    }

    static let minimumSmallerKbps = 64
    static let maximumSmallerKbps = 256
    static let minimumFitKbps = 32
    static let lossless: Set<String> = ["wav", "aiff", "flac"]

    /// The bitrate for each compress tier, used when a selection mixes audio with other kinds of files.
    public static func kbps(for tier: CompressTier) -> Int {
        switch tier {
        case .light: 192
        case .medium: 128
        case .strong: 96
        }
    }

    /// The format of the result: the source's own, or m4a when compressing a lossless source.
    public static func outputFormat(for item: DroppedItem, op: Operation) throws -> OutputFormat {
        guard let own = OutputFormat(rawValue: item.formatKey), ConversionMatrix.table(for: .audio).contains(own) else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        if case .compress = op, lossless.contains(item.formatKey) { return .m4a }
        return own
    }

    /// True when the tool can't run without ffmpeg: the source needs it to be read or the result needs it to be written.
    public static func requiresFFmpeg(_ item: DroppedItem, op: Operation) -> Bool {
        if MediaSupport.needsFFmpegToRead(item) { return true }
        guard let format = try? outputFormat(for: item, op: op) else { return false }
        return !MediaSupport.nativeAudioWrite.contains(format)
    }

    /// Runs `op` on `item` and writes the result to `output`. `scratch` makes a temporary folder (at most once).
    public static func process(_ item: DroppedItem, op: Operation, output: URL, ffmpeg: FFmpeg?,
                               scratch: () throws -> URL,
                               progress: @escaping @Sendable (Double) -> Void) async throws {
        let format = try outputFormat(for: item, op: op)
        var folder: URL?
        func scratchFolder() throws -> URL {
            if let folder { return folder }
            let made = try scratch()
            folder = made
            return made
        }

        // Compressing into a format only ffmpeg writes is a plain re-encode: no decoding step needed.
        if case .compress(let rate) = op, !MediaSupport.nativeAudioWrite.contains(format) {
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            let seconds = try await ffmpeg.duration(of: item.url)
            let kbps = try resolve(rate, item: item, seconds: seconds)
            try await ffmpeg.run(inputs: [item.url], args: AudioConverter.recipe(for: format, kbps: kbps), output: output,
                                 duration: seconds, progress: progress)
            return
        }

        // 1. Decode.
        let usesFFmpegToRead = MediaSupport.needsFFmpegToRead(item)
        let input: AVAudioFile
        if !usesFFmpegToRead, let native = try? AVAudioFile(forReading: item.url) {
            input = native
        } else {
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            let wav = try scratchFolder().appending(path: "decoded.wav", directoryHint: .notDirectory)
            let seconds = try? await ffmpeg.duration(of: item.url)
            try await ffmpeg.run(inputs: [item.url], args: ["-map", "0:a:0", "-vn", "-c:a", "pcm_s16le"], output: wav,
                                 duration: seconds, progress: { progress($0 * 0.3) })
            input = try AVAudioFile(forReading: wav)
        }
        let sampleRate = input.processingFormat.sampleRate
        let seconds = Double(input.length) / sampleRate
        let inChannels = Int(input.processingFormat.channelCount)
        var outChannels = inChannels
        if case .channels(let channelOp) = op {
            switch channelOp {
            case .toMono: outChannels = 1
            case .toStereo: outChannels = 2
            case .swap: break
            }
        }
        var kbps = AudioConverter.aacKbps
        var variable = false
        if case .compress(let rate) = op {
            kbps = try resolve(rate, item: item, seconds: seconds)
            variable = rate == .smaller
        }

        // 2. Process and 3. write.
        let writesNatively = MediaSupport.nativeAudioWrite.contains(format)
            && !((format == .m4a || format == .aac) && outChannels > 2 && ffmpeg != nil)
        let decodeShare = usesFFmpegToRead ? 0.3 : 0
        let encodeShare = writesNatively ? 0 : 0.3
        let work: @Sendable (Double) -> Void = { progress(decodeShare + $0 * (1 - decodeShare - encodeShare)) }
        // The writer is local to this function, so the file is complete (and closed) when it returns.
        func write(to url: URL, as fileFormat: OutputFormat, progress: (Double) -> Void) throws {
            let writer = try AudioConverter.makeWriter(url, format: fileFormat, sampleRate: sampleRate,
                                                       channels: outChannels, kbps: kbps, variable: variable)
            try render(op, from: input, to: writer, progress: progress)
        }
        if writesNatively {
            if format == .m4a {
                try await AudioConverter.encodeM4A(to: output, tags: await AudioMetadata.carriedTags(from: item.url),
                                                   progress: work, write: { try write(to: $0, as: .m4a, progress: $1) })
            } else {
                try write(to: output, as: format, progress: work)
            }
        } else {
            guard let ffmpeg else { throw OrbitError.helperMissing(.ffmpeg) }
            let processed = try scratchFolder().appending(path: "processed.wav", directoryHint: .notDirectory)
            try write(to: processed, as: .wav, progress: work)
            let encodeKbps: Int? = { if case .compress = op { kbps } else { nil } }()
            try await ffmpeg.run(inputs: [processed, item.url],
                                 args: ["-map", "0:a", "-map_metadata", "1"] + AudioConverter.recipe(for: format, kbps: encodeKbps),
                                 output: output, duration: seconds,
                                 progress: { progress(1 - encodeShare + $0 * encodeShare) })
        }
        progress(1)
    }

    // MARK: Bitrate

    /// The kbps for a compress request: `.smaller` is half of the source's average bitrate (between 64
    /// and 256), and a size target is met with a little headroom.
    static func resolve(_ rate: Rate, item: DroppedItem, seconds: Double) throws -> Int {
        switch rate {
        case .kbps(let kbps):
            return max(kbps, 8)
        case .smaller:
            let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard seconds > 0, size > 0 else { return minimumSmallerKbps }
            let source = Double(size) * 8 / seconds / 1000
            return min(maximumSmallerKbps, max(minimumSmallerKbps, Int((source / 2).rounded())))
        case .fitUnder(let bytes):
            guard seconds > 0 else { throw OrbitError.unsupported("Couldn't read the length of \(item.url.lastPathComponent).") }
            let kbps = Int(Double(bytes) * 8 * 0.95 / seconds / 1000)
            guard kbps >= minimumFitKbps else {
                throw OrbitError.targetTooSmall("Can't get this audio under \(bytes) bytes.")
            }
            return min(kbps, 320)
        }
    }

    // MARK: Rendering

    private static func render(_ op: Operation, from input: AVAudioFile, to writer: AVAudioFile,
                               progress: (Double) -> Void) throws {
        let rate = input.processingFormat.sampleRate
        switch op {
        case .compress:
            try AudioConverter.copy(from: input, to: writer, progress: progress)
        case .trim(let range):
            let start = AVAudioFramePosition((max(range.lowerBound, 0) * rate).rounded())
            let end = min(AVAudioFramePosition((range.upperBound * rate).rounded()), input.length)
            guard end > start, start < input.length else {
                throw OrbitError.unsupported("The part to keep is outside this audio.")
            }
            try AudioConverter.copy(from: input, to: writer, startFrame: start, frameCount: end - start, progress: progress)
        case .normalize:
            // Measure first (half the progress), then apply one gain to the whole file.
            var meter = AudioDSP.Meter()
            try AudioConverter.measure(input, into: &meter, progress: { progress($0 * 0.5) })
            let gain = Float(AudioDSP.gainToNormalize(rmsDB: meter.rmsDB, peakDB: meter.peakDB))
            try AudioConverter.copy(from: input, to: writer, progress: { progress(0.5 + $0 * 0.5) }, transform: { buffer, _ in
                AudioDSP.applyGain(buffer, gain)
                return buffer
            })
        case .bleep(let ranges):
            try AudioConverter.copy(from: input, to: writer, progress: progress, transform: { buffer, start in
                AudioDSP.applyBleep(buffer, ranges: ranges, startFrame: start)
                return buffer
            })
        case .channels(let channelOp):
            try AudioConverter.copy(from: input, to: writer, progress: progress, transform: { buffer, _ in
                AudioDSP.remix(buffer, op: channelOp)
            })
        }
    }
}
