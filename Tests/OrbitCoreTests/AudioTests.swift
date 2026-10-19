import AVFoundation
import Accelerate
import Foundation
import Testing
@testable import OrbitCore

private func rmsDB(_ s: [Float]) -> Double {
    guard !s.isEmpty else { return -.infinity }
    var mean: Float = 0
    vDSP_measqv(s, 1, &mean, vDSP_Length(s.count))
    return 10 * log10(Double(mean))
}

private func peakDB(_ s: [Float]) -> Double {
    var peak: Float = 0
    vDSP_maxmgv(s, 1, &peak, vDSP_Length(s.count))
    return 20 * log10(Double(peak))
}

@Suite final class AudioTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    var ff: FFmpeg { FFmpeg(executable: Fixtures.ffmpeg!) }

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func runner(_ caps: Capabilities) -> JobRunner {
        let rootPath = root.path + "/"
        return JobRunner(
            processors: ProcessorRegistry.standard(capabilities: caps), capabilities: caps, fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
    }

    @discardableResult
    private func run(_ url: URL, _ action: SliceAction, _ parameters: ToolParameters = .none,
                     caps: Capabilities = Fixtures.caps) async throws -> JobResult {
        let result = try await runner(caps).run(JobRequest(items: [DroppedItem(url: url)], action: action, parameters: parameters),
                                                progress: { _ in })
        if let failure = result.failures.first { throw OrbitError.unsupported(failure.message) }
        return result
    }

    private func tone(_ name: String, seconds: Double = 3, freq: Double = 440, amplitude: Double = 0.1, channels: Int = 2,
                      rightSilent: Bool = false) -> URL {
        Fixtures.tone(name, seconds: seconds, freq: freq, amplitude: amplitude, channels: channels, rightSilent: rightSilent, in: root)
    }

    /// Runs one tool over a file (a name makes a 3 s stereo tone) and returns its single output.
    private func tool(_ src: URL, _ id: ToolID, _ parameters: ToolParameters = .none, preset: Preset? = nil,
                      caps: Capabilities = Fixtures.caps) async throws -> URL {
        try await run(src, .tool(id, preset), parameters, caps: caps).outputs[0]
    }

    private func tool(_ name: String, _ id: ToolID, _ parameters: ToolParameters = .none, preset: Preset? = nil) async throws -> URL {
        try await tool(tone(name), id, parameters, preset: preset)
    }

    private func bytes(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Brief tests

    @Test(arguments: [OutputFormat.m4a, .aac, .aiff, .flac])
    func wavToNative(f: OutputFormat) async throws {
        let o = try await run(tone("a.wav", amplitude: 0.1), .convert(f)).outputs[0]
        #expect(o.pathExtension == f.fileExtension)
        // A bare AAC stream (ADTS) can't record the encoder's 2112 frames of priming, so it reads about 65 ms long.
        #expect(abs(try await MediaInfo.duration(o) - 3) < (f == .aac ? 0.1 : 0.06))
        #expect(try await MediaInfo.channelCount(o) == 2)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg), arguments: [OutputFormat.mp3, .ogg, .opus, .wma])
    func wavToFFmpeg(f: OutputFormat) async throws {
        let o = try await run(tone("a.wav", amplitude: 0.1), .convert(f)).outputs[0]
        #expect(abs(try await ff.duration(of: o) - 3) < 0.1)
    }

    @Test func wavCompressBecomesM4A() async throws {
        #expect(try await tool("a.wav", .compress, preset: .bitrate(128)).pathExtension == "m4a")
    }

    @Test func trim() async throws {
        #expect(abs(try await MediaInfo.duration(tool("a.wav", .trim, .timeRange(1...2))) - 1) < 0.05)
    }

    @Test func normalize() async throws {
        let o = try await tool(tone("q.wav", seconds: 2, amplitude: 0.05), .normalize)
        let s = Fixtures.readSamples(o)[0]
        #expect(abs(rmsDB(s) + 16) < 1)
        #expect(peakDB(s) <= -1 + 0.05)
    }

    @Test func bleep() async throws {
        let src = tone("b.wav", amplitude: 0.1)
        let o = try await tool(src, .bleep, .bleepRanges([1...1.5]))
        let a = Fixtures.readSamples(src)[0], b = Fixtures.readSamples(o)[0], sr = 44_100
        #expect(zip(a[0..<sr], b[0..<sr]).allSatisfy { abs($0 - $1) < 1e-4 })
        #expect(abs(rmsDB(Array(b[sr + 100..<sr * 3 / 2 - 100])) + 15) < 1)
    }

    @Test func toMono() async throws {
        #expect(try await MediaInfo.channelCount(tool("a.wav", .channels, preset: .channels(.toMono))) == 1)
    }

    @Test func swap() async throws {
        let o = try await tool(tone("s.wav", seconds: 1, amplitude: 0.1, rightSilent: true), .channels, preset: .channels(.swap))
        let ch = Fixtures.readSamples(o)
        #expect(peakDB(ch[0]) < -80 && peakDB(ch[1]) > -25)
    }

    @Test func stripM4ATitle() async throws {
        let o = try await tool(await Fixtures.m4a(title: "Secret Title", in: root), .metadata, preset: .metadataStripAll)
        #expect(await AudioMetadata.read(o).first { $0.key == .title } == nil)
    }

    @Test func editM4ATitle() async throws {
        let o = try await tool(await Fixtures.m4a(title: "Old", in: root), .metadata, .metadata(["title": "New"]))
        #expect(await AudioMetadata.read(o).first { $0.key == .title }?.value == "New")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func trimMP3StaysMP3() async throws {
        let mp3 = try await run(tone("t.wav", amplitude: 0.1), .convert(.mp3)).outputs[0]
        let o = try await tool(mp3, .trim, .timeRange(1...2))
        #expect(o.pathExtension == "mp3")
        #expect(abs(try await ff.duration(of: o) - 1) < 0.1)
    }

    @Test func waveform() async throws {
        let p = try await Waveform.peaks(tone("w.wav", seconds: 1, amplitude: 0.5), buckets: 50)
        #expect(p.count == 50 && p.allSatisfy { abs($0 - 0.5) < 0.02 })
    }

    // MARK: Helpers for the extra tests

    /// The decoded samples of any audio file, through ffmpeg when AVFoundation can't read it.
    private func decoded(_ url: URL) async throws -> [[Float]] {
        let wav = root.appending(path: "decoded-\(UUID().uuidString.prefix(6)).wav")
        try await ff.run(inputs: [url], args: ["-vn", "-c:a", "pcm_s16le"], output: wav, duration: nil, progress: { _ in })
        return Fixtures.readSamples(wav)
    }

    private func mp3(title: String? = nil) async throws -> URL {
        let out = root.appending(path: "tagged-\(UUID().uuidString.prefix(6)).mp3")
        let tags = title.map { ["-metadata", "title=\($0)"] } ?? []
        try await ff.run(inputs: [tone("src-\(UUID().uuidString.prefix(6)).wav", amplitude: 0.1)],
                         args: ["-c:a", "libmp3lame", "-q:a", "2"] + tags, output: out, duration: nil, progress: { _ in })
        return out
    }

    private func buffer(_ channels: [[Float]], rate: Double = 44_100) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                                   channels: AVAudioChannelCount(channels.count), interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        b.frameLength = AVAudioFrameCount(channels[0].count)
        for (c, values) in channels.enumerated() { for (i, v) in values.enumerated() { b.floatChannelData![c][i] = v } }
        return b
    }

    private func samples(_ b: AVAudioPCMBuffer) -> [[Float]] {
        (0..<Int(b.format.channelCount)).map { Array(UnsafeBufferPointer(start: b.floatChannelData![$0], count: Int(b.frameLength))) }
    }

    // MARK: DSP

    @Test func normalizeGainReachesTargetUnlessPeakCaps() {
        func db(_ gain: Double) -> Double { 20 * log10(gain) }
        #expect(abs(db(AudioDSP.gainToNormalize(rmsDB: -30, peakDB: -20)) - 14) < 1e-9)
        // RMS wants +4 dB but the peak at -3 dBFS only has 2 dB of room before -1 dBFS.
        #expect(abs(db(AudioDSP.gainToNormalize(rmsDB: -20, peakDB: -3)) - 2) < 1e-9)
        // Louder than the target: turned down.
        #expect(abs(db(AudioDSP.gainToNormalize(rmsDB: -10, peakDB: -0.5)) + 6) < 1e-9)
        #expect(AudioDSP.gainToNormalize(rmsDB: -.infinity, peakDB: -.infinity) == 1)
    }

    @Test func meterMeasuresAcrossChunks() {
        let whole = buffer([[0.5, -0.5, 0.5, -0.5], [0.5, 0.5, -0.5, -0.5]])
        #expect(abs(AudioDSP.rmsDB(whole) - (-6.0206)) < 1e-3)
        #expect(abs(AudioDSP.peakDB(whole) - (-6.0206)) < 1e-3)
        var meter = AudioDSP.Meter()
        meter.add(buffer([[0.5, -0.5], [0.5, 0.5]]))
        meter.add(buffer([[0.5, -0.5], [-0.5, -0.5]]))
        #expect(abs(meter.rmsDB - AudioDSP.rmsDB(whole)) < 1e-6 && meter.peakDB == AudioDSP.peakDB(whole))
        #expect(AudioDSP.rmsDB(buffer([[0, 0]])) == -.infinity)
    }

    @Test func remixOperations() {
        let stereo = buffer([[0.2, 0.4], [0.6, 0.0]])
        let mono = samples(AudioDSP.remix(stereo, op: .toMono))
        #expect(mono.count == 1 && zip(mono[0], [0.4, 0.2]).allSatisfy { abs($0 - $1) < 1e-6 })
        #expect(samples(AudioDSP.remix(stereo, op: .swap)) == [[0.6, 0.0], [0.2, 0.4]])
        #expect(samples(AudioDSP.remix(stereo, op: .toStereo)) == [[0.2, 0.4], [0.6, 0.0]])
        #expect(samples(AudioDSP.remix(buffer([[0.1, 0.2]]), op: .toStereo)) == [[0.1, 0.2], [0.1, 0.2]])
        #expect(samples(AudioDSP.remix(buffer([[0.1, 0.2]]), op: .swap)) == [[0.1, 0.2]])
    }

    @Test func bleepToneIsContinuousAcrossChunks() {
        let silence = [Float](repeating: 0, count: 2000)
        let whole = buffer([silence])
        AudioDSP.applyBleep(whole, ranges: [0.01...0.03])
        let first = buffer([Array(silence[0..<700])]), second = buffer([Array(silence[700...])])
        AudioDSP.applyBleep(first, ranges: [0.01...0.03], startFrame: 0)
        AudioDSP.applyBleep(second, ranges: [0.01...0.03], startFrame: 700)
        #expect(samples(first)[0] + samples(second)[0] == samples(whole)[0])
        #expect(abs(AudioDSP.peakDB(whole) - AudioDSP.bleepPeakDB) < 0.1)
    }

    // MARK: Conversion

    @Test(arguments: [OutputFormat.wav, .aiff, .flac, .m4a])
    func nativeSourcesConvertBetweenFormats(target: OutputFormat) async throws {
        let source = try await run(tone("n.wav", amplitude: 0.1), .convert(target == .flac ? .aiff : .flac)).outputs[0]
        let o = try await run(source, .convert(target)).outputs[0]
        #expect(o.pathExtension == target.fileExtension)
        #expect(abs(try await MediaInfo.duration(o) - 3) < 0.06)
    }

    @Test func wavToAIFFAndBackKeepsTheSound() async throws {
        let src = tone("p.wav", amplitude: 0.25)
        let aiff = try await run(src, .convert(.aiff)).outputs[0]
        let back = try await run(aiff, .convert(.wav)).outputs[0]
        let a = Fixtures.readSamples(src), b = Fixtures.readSamples(back)
        #expect(a[0].count == b[0].count)
        #expect(zip(a[0], b[0]).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func aacStreamIsReadableAndConvertsOnward() async throws {
        let aac = try await run(tone("x.wav", amplitude: 0.1), .convert(.aac)).outputs[0]
        let wav = try await run(aac, .convert(.wav)).outputs[0]
        #expect(try await MediaInfo.channelCount(wav) == 2)
        #expect(abs(try await MediaInfo.duration(wav) - 3) < 0.1)
    }

    @Test func monoFilesStayMono() async throws {
        let m = try await run(tone("m.wav", amplitude: 0.1, channels: 1), .convert(.m4a)).outputs[0]
        #expect(try await MediaInfo.channelCount(m) == 1)
    }

    @Test func convertWithoutFFmpegSaysSo() async throws {
        let src = tone("h.wav", amplitude: 0.1)
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { try await run(src, .convert(.mp3), caps: Capabilities()) }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "h-converted.mp3").path))
        // Native formats still work without it.
        _ = try await run(src, .convert(.flac), caps: Capabilities())
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func ffmpegOnlySourceConvertsToNativeFormats() async throws {
        let ogg = try await run(tone("o.wav", amplitude: 0.1), .convert(.ogg)).outputs[0]
        let o = try await run(ogg, .convert(.m4a)).outputs[0]
        #expect(abs(try await MediaInfo.duration(o) - 3) < 0.1)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func unsafeFileNamesWorkWithFFmpeg() async throws {
        let src = tone("-rf 'q\" ü.wav", amplitude: 0.1)
        let o = try await run(src, .convert(.mp3)).outputs[0]
        #expect(o.lastPathComponent == "-rf 'q\" ü-converted.mp3")
        #expect(abs(try await ff.duration(of: o) - 3) < 0.1)
        let trimmed = try await tool(o, .trim, .timeRange(0...1))
        #expect(abs(try await ff.duration(of: trimmed) - 1) < 0.1)
    }

    @Test func sourcesAreNeverTouched() async throws {
        let src = tone("keep.wav", amplitude: 0.1)
        let before = try Data(contentsOf: src)
        let o = try await tool(src, .normalize)
        #expect(o.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL)
        #expect(o.lastPathComponent == "keep-normalized.wav")
        #expect(try Data(contentsOf: src) == before)
    }

    // MARK: Compress

    @Test func compressKeepsLossyFormatsAndShrinks() async throws {
        let big = try await run(tone("c.wav", amplitude: 0.1), .convert(.m4a)).outputs[0]
        let low = try await tool(big, .compress, preset: .bitrate(96))
        #expect(low.pathExtension == "m4a" && low.lastPathComponent.hasSuffix("-compressed.m4a"))
        #expect(bytes(low) < bytes(big))
        #expect(abs(try await MediaInfo.duration(low) - 3) < 0.06)
    }

    @Test func compressTiersAreOrderedByBitrate() async throws {
        let src = tone("t.wav", seconds: 6, freq: 1_234, amplitude: 0.2)
        func size(_ tier: CompressTier) async throws -> Int {
            bytes(try await tool(src, .compress, .compress(.tier(tier))))
        }
        let (light, medium, strong) = (try await size(.light), try await size(.medium), try await size(.strong))
        #expect(light > medium && medium > strong)
        #expect([192, 128, 96] == CompressTier.allCases.map(AudioTools.kbps(for:)))
    }

    @Test func smallerIsHalfTheSourceBitrateWithAFloor() async throws {
        let high = try await tool(tone("h.wav", seconds: 6, amplitude: 0.2), .compress, preset: .bitrate(256))
        let item = DroppedItem(url: high)
        let seconds = try await MediaInfo.duration(high)
        let source = Double(bytes(high)) * 8 / seconds / 1000
        #expect(try AudioTools.resolve(.smaller, item: item, seconds: seconds) == min(256, max(64, Int((source / 2).rounded()))))
        #expect(try AudioTools.resolve(.smaller, item: item, seconds: seconds) < 256)
        let low = DroppedItem(url: try await tool(item.url, .compress, preset: .bitrate(64)))
        #expect(try AudioTools.resolve(.smaller, item: low, seconds: seconds) == 64)
        // A lossless source is capped at the top AAC rate.
        let wav = DroppedItem(url: tone("l.wav", amplitude: 0.1))
        #expect(try AudioTools.resolve(.smaller, item: wav, seconds: 3) == 256)
        let smaller = try await tool(wav.url, .compress, preset: .bitrate(0))
        #expect(smaller.pathExtension == "m4a")
    }

    @Test func fitUnderPicksABitrateOrExplainsWhyNot() async throws {
        let src = tone("f.wav", seconds: 10, amplitude: 0.2)
        let o = try await tool(src, .compress, .compress(.fitUnder(100_000)))
        #expect(bytes(o) < 100_000)
        await #expect(throws: OrbitError.targetTooSmall("Can't get this audio under 5000 bytes.")) {
            try await tool(src, .compress, .compress(.fitUnder(5_000)))
        }
    }

    @Test func compressNeedsATarget() async throws {
        await #expect(throws: OrbitError.unsupported("Choose how small to make this audio.")) {
            try await tool("a.wav", .compress)
        }
    }

    @Test func compressReportsSizes() async throws {
        let result = try await run(tone("z.wav", amplitude: 0.1), .tool(.compress, .bitrate(96)))
        #expect(result.summary.contains("→"))
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg), arguments: [OutputFormat.mp3, .opus])
    func compressStaysInFormatThroughFFmpeg(f: OutputFormat) async throws {
        // A 192 kbps source (the recipes' own quality settings are variable, so a simple tone is tiny).
        let src = root.appending(path: "rich.\(f.fileExtension)")
        let codec = f == .mp3 ? "libmp3lame" : "libopus"
        try await ff.run(inputs: [tone("w.wav", seconds: 6, freq: 777, amplitude: 0.2)], args: ["-c:a", codec, "-b:a", "192k"],
                         output: src, duration: nil, progress: { _ in })
        let o = try await tool(src, .compress, preset: .bitrate(64))
        #expect(o.pathExtension == f.fileExtension)
        #expect(bytes(o) < bytes(src) / 2)
        #expect(abs(try await ff.duration(of: o) - 6) < 0.15)
    }

    // MARK: Trim, normalize, bleep, channels

    @Test func trimKeepsFormatAndRejectsEmptyRanges() async throws {
        let m4a = try await run(tone("t.wav", amplitude: 0.1), .convert(.m4a)).outputs[0]
        let o = try await tool(m4a, .trim, .timeRange(0.5...2))
        #expect(o.pathExtension == "m4a")
        #expect(abs(try await MediaInfo.duration(o) - 1.5) < 0.08)
        await #expect(throws: OrbitError.unsupported("The part to keep is outside this audio.")) {
            try await tool("u.wav", .trim, .timeRange(5...6))
        }
        await #expect(throws: OrbitError.unsupported("Choose the part to keep first.")) { try await tool("v.wav", .trim) }
    }

    @Test func trimKeepsTheRightSamples() async throws {
        let src = tone("k.wav", amplitude: 0.1)
        let o = try await tool(src, .trim, .timeRange(1...2))
        let a = Fixtures.readSamples(src)[0], b = Fixtures.readSamples(o)[0]
        #expect(b.count == 44_100)
        #expect(zip(a[44_100..<88_200], b).allSatisfy { abs($0 - $1) < 1e-4 })
    }

    @Test func normalizeBringsLoudAudioDownAndNeverClips() async throws {
        let o = try await tool(tone("loud.wav", seconds: 2, amplitude: 0.9), .normalize)
        let s = Fixtures.readSamples(o)[0]
        #expect(abs(rmsDB(s) + 16) < 1)
        #expect(peakDB(s) <= -1 + 0.05)
        // Silence stays silence.
        let quiet = Fixtures.readSamples(try await tool(tone("quiet.wav", seconds: 1, amplitude: 0), .normalize))[0]
        #expect(quiet.allSatisfy { $0 == 0 })
    }

    @Test func normalizeIsCappedByThePeak() async throws {
        // A spike on a quiet bed: RMS would want a big boost, the peak allows only a little.
        let spiked = root.appending(path: "spiked.wav")
        let b = buffer(Fixtures.readSamples(tone("bed.wav", seconds: 2, amplitude: 0.01)))
        b.floatChannelData![0][50] = 0.5
        do {
            let file = try AVAudioFile(forWriting: spiked, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            ])
            try file.write(from: b)
        }
        let out = Fixtures.readSamples(try await tool(spiked, .normalize))[0]
        #expect(abs(peakDB(out) + 1) < 0.1)
        #expect(rmsDB(out) < -16)
    }

    @Test func bleepNeedsRanges() async throws {
        await #expect(throws: OrbitError.unsupported("Mark the parts to bleep first.")) { try await tool("e.wav", .bleep) }
    }

    @Test func monoToStereoDuplicatesAndStereoToMonoAverages() async throws {
        let mono = tone("mono.wav", seconds: 1, amplitude: 0.2, channels: 1)
        let stereo = try await tool(mono, .channels, preset: .channels(.toStereo))
        let ch = Fixtures.readSamples(stereo)
        #expect(ch.count == 2 && ch[0] == ch[1] && peakDB(ch[0]) > -15)
        let half = try await tool(tone("half.wav", seconds: 1, amplitude: 0.2, rightSilent: true), .channels, preset: .channels(.toMono))
        let m = Fixtures.readSamples(half)
        #expect(m.count == 1 && abs(peakDB(m[0]) - 20 * log10(0.1)) < 0.2)
        #expect(half.lastPathComponent == "half-mono.wav")
    }

    @Test func channelsKeepFormatForM4A() async throws {
        let m4a = try await run(tone("c.wav", amplitude: 0.1), .convert(.m4a)).outputs[0]
        let o = try await tool(m4a, .channels, preset: .channels(.toMono))
        #expect(o.pathExtension == "m4a")
        #expect(try await MediaInfo.channelCount(o) == 1)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func ffmpegOnlySourcesAreProcessedAndKeepTheirFormat() async throws {
        let ogg = try await run(tone("q.wav", seconds: 2, amplitude: 0.05), .convert(.ogg)).outputs[0]
        let o = try await tool(ogg, .normalize)
        #expect(o.pathExtension == "ogg")
        let s = try await decoded(o)[0]
        #expect(abs(rmsDB(s) + 16) < 1.5)
        #expect(try await tool(ogg, .channels, preset: .channels(.toMono)).pathExtension == "ogg")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func ffmpegEncodedResultsKeepTheTags() async throws {
        let src = try await mp3(title: "Keep Me")
        let o = try await tool(src, .normalize)
        #expect(o.pathExtension == "mp3")
        #expect(await AudioMetadata.read(o, ffmpeg: ff).first { $0.key == .title }?.value == "Keep Me")
    }

    /// Ogg and Opus keep their tags on the audio stream rather than the file, so they need their own check.
    private func streamTagged(_ f: OutputFormat, title: String, artist: String? = nil) async throws -> URL {
        let out = root.appending(path: "tagged-\(UUID().uuidString.prefix(6)).\(f.fileExtension)")
        var tags = ["-metadata", "title=\(title)"]
        if let artist { tags += ["-metadata", "artist=\(artist)"] }
        try await ff.run(inputs: [tone("src-\(UUID().uuidString.prefix(6)).wav", amplitude: 0.1)],
                         args: FFmpegRecipes.args(for: f) + tags, output: out, duration: nil, progress: { _ in })
        return out
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg), arguments: [OutputFormat.ogg, .opus])
    func ffmpegEncodedOggAndOpusResultsKeepTheirStreamTags(f: OutputFormat) async throws {
        let src = try await streamTagged(f, title: "Stream Title", artist: "Stream Artist")
        #expect(await AudioMetadata.read(src, ffmpeg: ff).first { $0.key == .title }?.value == "Stream Title")
        for (id, preset) in [(ToolID.normalize, nil), (.channels, Preset.channels(.toMono))] as [(ToolID, Preset?)] {
            let o = try await tool(src, id, preset: preset)
            #expect(o.pathExtension == f.fileExtension)
            let fields = await AudioMetadata.read(o, ffmpeg: ff)
            #expect(fields.first { $0.key == .title }?.value == "Stream Title")
            #expect(fields.first { $0.key == .artist }?.value == "Stream Artist")
        }
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg), arguments: [OutputFormat.ogg, .opus])
    func editingAnOggOrOpusTitleReplacesTheOldOne(f: OutputFormat) async throws {
        let src = try await streamTagged(f, title: "Old Title", artist: "Band")
        let o = try await tool(src, .metadata, .metadata(["title": "New Title", "album": "LP"]))
        let fields = await AudioMetadata.read(o, ffmpeg: ff)
        #expect(fields.first { $0.key == .title }?.value == "New Title")
        #expect(fields.first { $0.key == .album }?.value == "LP")
        #expect(fields.first { $0.key == .artist }?.value == "Band")
    }

    @Test func toolsNeedFFmpegForFormatsOnlyItWrites() async throws {
        let wav = tone("g.wav", amplitude: 0.1)
        let fake = root.appending(path: "fake.mp3")
        try Data(count: 64).write(to: fake)
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { try await tool(fake, .normalize, caps: Capabilities()) }
        #expect(!AudioTools.requiresFFmpeg(DroppedItem(url: wav), op: .normalize))
        #expect(AudioTools.requiresFFmpeg(DroppedItem(url: fake), op: .normalize))
        _ = try await tool(wav, .normalize, caps: Capabilities())
    }

    // MARK: Metadata

    @Test func readListsTagsAndDuration() async throws {
        let m = await Fixtures.m4a(title: "Song", artist: "Band", in: root)
        let fields = await AudioMetadata.read(m)
        #expect(fields.first { $0.key == .title }?.value == "Song")
        #expect(fields.first { $0.key == .artist }?.value == "Band")
        #expect(fields.first { $0.key == .album } == nil)
        #expect(fields.first { $0.key == .duration }?.value == "0:02")
        #expect(fields.filter(\.editable).map(\.key) == [.title, .artist])
        #expect(AudioMetadata.editableKeys == [.title, .artist, .album])
    }

    @Test func editM4AKeepsOtherTagsAndCanAddAlbumAndArtwork() async throws {
        let m = await Fixtures.m4a(title: "Song", artist: "Band", in: root)
        let cover = Fixtures.coverPNG(in: root)
        let o = try await tool(m, .metadata, .metadata(["album": "LP", "artist": "Other", "artwork": cover.path]))
        let fields = await AudioMetadata.read(o)
        #expect(fields.first { $0.key == .title }?.value == "Song")
        #expect(fields.first { $0.key == .artist }?.value == "Other")
        #expect(fields.first { $0.key == .album }?.value == "LP")
        let items = try await AVURLAsset(url: o).load(.metadata)
        #expect(!AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork).isEmpty)
        #expect(o.lastPathComponent.hasSuffix("-edited.m4a"))
        // An empty value removes the tag.
        let cleared = try await tool(o, .metadata, .metadata(["artist": ""]))
        #expect(await AudioMetadata.read(cleared).first { $0.key == .artist } == nil)
        #expect(await AudioMetadata.read(cleared).first { $0.key == .title }?.value == "Song")
    }

    @Test func stripM4AKeepsTheAudio() async throws {
        let m = await Fixtures.m4a(title: "Secret", artist: "Someone", in: root)
        let o = try await tool(m, .metadata, preset: .metadataStripAll)
        #expect(o.lastPathComponent.hasSuffix("-clean.m4a"))
        #expect(await AudioMetadata.read(o).filter(\.editable).isEmpty)
        #expect(abs(try await MediaInfo.duration(o) - 2) < 0.1)
        #expect(try await MediaInfo.channelCount(o) == 2)
    }

    @Test func editRejectsEmptyAndBadInput() async throws {
        let m = await Fixtures.m4a(title: "T", in: root)
        await #expect(throws: OrbitError.unsupported("There are no metadata changes to save.")) {
            try await tool(m, .metadata, .metadata([:]))
        }
        await #expect(throws: OrbitError.unsupported("There are no metadata changes to save.")) {
            try await tool(m, .metadata, .none)
        }
        let notAnImage = Fixtures.file("cover.txt", "hello", in: root)
        await #expect(throws: OrbitError.unsupported("Cover art must be a JPEG or PNG image.")) {
            try await tool(m, .metadata, .metadata(["artwork": notAnImage.path]))
        }
    }

    @Test func stripWAVWithoutFFmpegRewritesNatively() async throws {
        let o = try await tool(tone("s.wav", amplitude: 0.1), .metadata, preset: .metadataStripAll, caps: Capabilities())
        #expect(o.pathExtension == "wav")
        #expect(abs(try await MediaInfo.duration(o) - 3) < 0.01)
        let source = tone("e.wav", amplitude: 0.1)
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) {
            try await tool(source, .metadata, .metadata(["title": "x"]), caps: Capabilities())
        }
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func stripAndEditMP3ThroughFFmpeg() async throws {
        let src = try await mp3(title: "Old Title")
        #expect(await AudioMetadata.read(src, ffmpeg: ff).first { $0.key == .title }?.value == "Old Title")
        let clean = try await tool(src, .metadata, preset: .metadataStripAll)
        #expect(clean.pathExtension == "mp3")
        #expect(await AudioMetadata.read(clean, ffmpeg: ff).first { $0.key == .title } == nil)
        let cover = Fixtures.coverPNG(in: root)
        let edited = try await tool(src, .metadata, .metadata(["title": "New Title", "album": "LP", "artwork": cover.path]))
        let fields = await AudioMetadata.read(edited, ffmpeg: ff)
        #expect(fields.first { $0.key == .title }?.value == "New Title")
        #expect(fields.first { $0.key == .album }?.value == "LP")
        let info = try await ProcessRunner.runCapturing(Fixtures.ffmpeg!, ["-hide_banner", "-i", FFmpeg.pathArg(edited)])
        #expect(FFmpeg.hasVideoStream(info.stderr)) // the attached picture
        #expect(abs(try await ff.duration(of: edited) - 3) < 0.1)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg))
    func stripFLACKeepsTheSound() async throws {
        let flac = try await run(tone("m.wav", amplitude: 0.1), .convert(.flac)).outputs[0]
        let tagged = root.appending(path: "tagged.flac")
        try await ff.run(inputs: [flac], args: ["-c", "copy", "-metadata", "title=Flac Title"], output: tagged,
                         duration: nil, progress: { _ in })
        #expect(await AudioMetadata.read(tagged, ffmpeg: ff).first { $0.key == .title }?.value == "Flac Title")
        let clean = try await tool(tagged, .metadata, preset: .metadataStripAll)
        #expect(clean.pathExtension == "flac")
        #expect(await AudioMetadata.read(clean, ffmpeg: ff).first { $0.key == .title } == nil)
        #expect(Fixtures.readSamples(clean)[0].count == Fixtures.readSamples(tagged)[0].count)
    }

    @Test func aacCannotBeRetagged() async throws {
        let aac = try await run(tone("a.wav", amplitude: 0.1), .convert(.aac)).outputs[0]
        await #expect(throws: OrbitError.unsupported("AAC files can't hold tags. Convert to M4A first.")) {
            try await tool(aac, .metadata, .metadata(["title": "x"]))
        }
        let clean = try await tool(aac, .metadata, preset: .metadataStripAll)
        #expect(clean.pathExtension == "aac" && bytes(clean) == bytes(aac))
    }

    // MARK: Waveform

    @Test func waveformCoversEdgeCases() async throws {
        let src = tone("w.wav", seconds: 2, amplitude: 0.8)
        let p = try await Waveform.peaks(src, buckets: 10)
        #expect(p.count == 10 && p.allSatisfy { abs($0 - 0.8) < 0.02 })
        let silent = try await Waveform.peaks(tone("s.wav", seconds: 1, amplitude: 0), buckets: 7)
        #expect(silent == [Float](repeating: 0, count: 7))
        #expect(try await Waveform.peaks(src, buckets: 0).isEmpty)
        // More buckets than frames still yields exactly that many.
        #expect(try await Waveform.peaks(tone("tiny.wav", seconds: 0.001, amplitude: 0.5), buckets: 100).count == 100)
    }

    @Test func waveformSeesLoudAndQuietParts() async throws {
        let bleeped = try await tool(tone("b.wav", seconds: 2, amplitude: 0.8), .bleep, .bleepRanges([1.5...2]))
        let p = try await Waveform.peaks(bleeped, buckets: 4)
        #expect(abs(p[0] - 0.8) < 0.02 && abs(p[3] - 0.2512) < 0.02)
    }

    @Test func waveformReadsCompressedFilesAndRejectsMissingOnes() async throws {
        let m4a = try await run(tone("w.wav", seconds: 2, amplitude: 0.5), .convert(.m4a)).outputs[0]
        let p = try await Waveform.peaks(m4a, buckets: 20)
        #expect(p.count == 20 && p.dropFirst().dropLast().allSatisfy { abs($0 - 0.5) < 0.1 })
        await #expect(throws: OrbitError.self) { try await Waveform.peaks(root.appending(path: "missing.wav"), buckets: 5) }
    }
}
