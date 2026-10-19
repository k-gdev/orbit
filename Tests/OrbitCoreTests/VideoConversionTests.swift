import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OrbitCore

@Suite final class VideoConversionTests {
    let root = Fixtures.tempDir()
    let fallback: URL

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

    private func run(_ url: URL, _ action: SliceAction, caps: Capabilities = Fixtures.caps) async throws -> JobResult {
        let result = try await runner(caps).run(JobRequest(items: [DroppedItem(url: url)], action: action), progress: { _ in })
        if let failure = result.failures.first { throw OrbitError.unsupported(failure.message) }
        return result
    }

    private func clip(_ name: String = "a.mov") async -> URL {
        await Fixtures.video(name, seconds: 2, w: 320, h: 240, in: root)
    }

    private func gifLoopCount(_ src: CGImageSource) -> Int? {
        let props = CGImageSourceCopyProperties(src, nil) as? [CFString: Any]
        return (props?[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int
    }

    private func mtime(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    @Test func movToMP4() async throws {
        let o = try await run(await clip(), .convert(.mp4)).outputs[0]
        #expect(abs(try await MediaInfo.duration(o) - 2) < 0.1)
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 320, height: 240))
        #expect(try await MediaInfo.hasAudio(o))
    }

    @Test func movToGIF() async throws {
        let o = try await run(await clip(), .convert(.gif)).outputs[0]
        let src = try #require(CGImageSourceCreateWithURL(o as CFURL, nil))
        #expect(abs(CGImageSourceGetCount(src) - 24) <= 2)
        #expect(gifLoopCount(src) == 0)
    }

    @Test func gifFrameCountIsCapped() {
        #expect(GIFMaker.plan(duration: 10, fps: 12)?.count == 120)
        let long = GIFMaker.plan(duration: 120, fps: 12)
        #expect(long?.count == GIFMaker.maxFrames)
        #expect((long?.fps ?? 99) < 12)
        #expect(GIFMaker.plan(duration: GIFMaker.maxDuration(for: CGSize(width: 480, height: 270)) + 1, fps: 12) == nil)
    }

    @Test func gifFrameBudgetIsByPixelsForTallClips() {
        let size = GIFMaker.outputSize(for: CGSize(width: 1080, height: 1920), maxSide: 480)
        #expect(size == CGSize(width: 270, height: 480))
        let long = GIFMaker.plan(duration: 120, fps: 12, size: size)
        #expect(long != nil)
        #expect(Int(size.width * size.height) * (long?.count ?? .max) <= GIFMaker.maxPixels)
        // A square clip has more pixels per frame, so it gets fewer frames than a 16:9 one.
        let square = GIFMaker.outputSize(for: CGSize(width: 1000, height: 1000), maxSide: 480)
        #expect(square == CGSize(width: 480, height: 480))
        #expect(GIFMaker.frameBudget(for: square) < GIFMaker.maxFrames)
        #expect(Int(square.width * square.height) * GIFMaker.frameBudget(for: square) <= GIFMaker.maxPixels)
        // Never scaled up; an uncapped 1080x1920 frame would blow the budget at 600 frames.
        #expect(GIFMaker.outputSize(for: CGSize(width: 100, height: 50), maxSide: 480) == CGSize(width: 100, height: 50))
        #expect(GIFMaker.frameBudget(for: CGSize(width: 1080, height: 1920)) < GIFMaker.maxFrames)
    }

    @Test func movToM4A() async throws {
        let o = try await run(await clip(), .convert(.m4a)).outputs[0]
        #expect(try await !MediaInfo.hasVideo(o))
        #expect(abs(try await MediaInfo.duration(o) - 2) < 0.1)
    }

    @Test func mediaInfoReadsRotationAndChannels() async throws {
        let rotated = await Fixtures.video("r.mov", seconds: 1, w: 320, h: 240, rotated: true, in: root)
        #expect(try await MediaInfo.videoSize(rotated) == CGSize(width: 320, height: 240))
        let track = try #require(try await AVURLAsset(url: rotated).loadTracks(withMediaType: .video).first)
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        #expect(CGRect(origin: .zero, size: natural).applying(transform).origin == .zero)
        #expect(try await MediaInfo.channelCount(rotated) == 1)
        let silent = await Fixtures.video("s.mov", seconds: 1, w: 64, h: 64, audio: false, in: root)
        #expect(try await !MediaInfo.hasAudio(silent))
        #expect(try await MediaInfo.channelCount(silent) == 0)
    }

    @Test func ffmpegRecipesCoverEveryVideoAndAudioOutput() {
        #expect(FFmpegRecipes.args(for: .mkv) == ["-c", "copy"])
        #expect(FFmpegRecipes.args(for: .mp4).contains("+faststart"))
        #expect(FFmpegRecipes.args(for: .mp3) == ["-vn", "-c:a", "libmp3lame", "-q:a", "2"])
        for f in [OutputFormat.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus, .wma] {
            #expect(!FFmpegRecipes.args(for: f).isEmpty)
        }
    }

    /// FFmpeg only allows `-q:v` for h264_videotoolbox when it runs as arm64; elsewhere a bitrate is used.
    @Test func videoToolboxRecipesUseABitrateWithoutQScale() {
        for f in [OutputFormat.mp4, .mov] {
            #expect(FFmpegRecipes.args(for: f, qscale: true).contains("-q:v"))
            let intel = FFmpegRecipes.args(for: f, qscale: false)
            #expect(!intel.contains("-q:v") && intel.contains("-b:v") && intel.contains("h264_videotoolbox"))
        }
        #expect(!FFmpegRecipes.mkvFallback(qscale: false).contains("-q:v"))
        for ext in ["mkv", "mp4", "mov", "m4v"] {
            let args = VideoToolsFFmpeg.reencodeArgs(for: URL(fileURLWithPath: "/x/a.\(ext)"), qscale: false)
            #expect(!args.contains("-q:v") && args.contains("-b:v"), "\(ext)")
        }
        #expect(FFmpeg(executable: URL(fileURLWithPath: "/x"), videoToolboxQScale: false).videoToolboxQScale == false)
    }

    @Test func machOSliceDetection() throws {
        func header(_ bytes: [UInt8]) throws -> URL {
            let url = root.appending(path: "bin-\(UUID().uuidString)")
            try Data(bytes + [UInt8](repeating: 0, count: 64)).write(to: url)
            return url
        }
        let thinARM = try header([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        let thinIntel = try header([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
        let fatIntel = try header([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 1, 0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16))
        let fatBoth = try header([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2, 0x01, 0x00, 0x00, 0x07] + [UInt8](repeating: 0, count: 16)
                                 + [0x01, 0x00, 0x00, 0x0C] + [UInt8](repeating: 0, count: 16))
        #expect(FFmpeg.hasARM64Slice(thinARM) && FFmpeg.hasARM64Slice(fatBoth))
        #expect(!FFmpeg.hasARM64Slice(thinIntel) && !FFmpeg.hasARM64Slice(fatIntel))
        #expect(!FFmpeg.hasARM64Slice(root.appending(path: "missing")))
        #if arch(arm64)
        #expect(FFmpeg.hasARM64Slice(URL(fileURLWithPath: "/bin/ls")))
        #endif
    }

    /// The MKV retry never removes a file that was already at the output path (it isn't Orbit's).
    @Test(.enabled(if: Fixtures.hasFFmpeg)) func mkvRetryLeavesAStrangersFileAlone() async throws {
        let src = await clip()
        let existing = Fixtures.file("taken.mkv", "mine", in: root)
        await #expect(throws: OrbitError.self) {
            try await VideoConverter.convert(DroppedItem(url: src), to: .mkv, output: existing,
                                             ffmpeg: FFmpeg(executable: Fixtures.ffmpeg!), progress: { _ in })
        }
        #expect(try String(contentsOf: existing, encoding: .utf8) == "mine")
        #expect(FFmpeg.isExistingOutputRefusal(OrbitError.processFailed(tool: "ffmpeg", code: 1, stderr: "Output file already exists.")))
        #expect(!FFmpeg.isExistingOutputRefusal(OrbitError.processFailed(tool: "ffmpeg", code: 1, stderr: "Invalid data")))
    }

    /// ffmpeg's palette pass buffers every frame, so the ffmpeg GIF path shares the native frame budget.
    @Test func ffmpegGIFArgsCapFrames() {
        let args = FFmpegRecipes.gif(fps: 4.5, size: CGSize(width: 480, height: 270), frames: 600)
        #expect(args.contains { $0.hasPrefix("fps=4.5,scale=480:270:flags=lanczos,split") })
        let frames = try? #require(args.firstIndex(of: "-frames:v"))
        #expect(frames.map { args[$0 + 1] } == "600")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func ffmpegGIFRefusesALongClip() async throws {
        let long = root.appending(path: "long.mkv")
        _ = try await ProcessRunner.run(Fixtures.ffmpeg!, ["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
                                                           "color=c=red:s=64x48:r=2:d=320", "-c:v", "mpeg4", FFmpeg.pathArg(long)])
        await #expect(throws: OrbitError.unsupported("long.mkv is too long for a GIF (5 minutes at most).")) {
            _ = try await self.run(long, .convert(.gif))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasSuffix(".gif") }.isEmpty)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func ffmpegGIFFromMKV() async throws {
        let o = try await run(await Fixtures.mkv(seconds: 2, in: root), .convert(.gif)).outputs[0]
        let src = try #require(CGImageSourceCreateWithURL(o as CFURL, nil))
        #expect(CGImageSourceGetCount(src) > 10 && CGImageSourceGetCount(src) <= 25)
        #expect(Fixtures.size(o) == CGSize(width: 320, height: 240))
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg), arguments: [OutputFormat.mkv, .webm, .avi, .wmv, .mp3])
    func ffmpegOutputs(f: OutputFormat) async throws {
        let o = try await run(await clip(), .convert(f)).outputs[0]
        #expect(abs(try await FFmpeg(executable: Fixtures.ffmpeg!).duration(of: o) - 2) < 0.2)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func mkvToMP4() async throws {
        let o = try await run(await Fixtures.mkv(seconds: 2, in: root), .convert(.mp4)).outputs[0]
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 320, height: 240))
    }

    @Test func mkvWithoutFFmpeg() async throws {
        let mkv = Fixtures.file("a.mkv", "not really a video", in: root)
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { try await run(mkv, .convert(.mp4), caps: Capabilities()) }
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) {
            try await VideoConverter.convert(DroppedItem(url: mkv), to: .mp4,
                                              output: root.appending(path: "b-out.mp4"), ffmpeg: nil, progress: { _ in })
        }
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func proxyIsCached() async throws {
        let m = await Fixtures.mkv(seconds: 2, in: root)
        let f = FFmpeg(executable: Fixtures.ffmpeg!)
        let cache = root.appending(path: "proxies", directoryHint: .isDirectory)
        let p1 = try await ProxyMaker.proxy(for: m, ffmpeg: f, audioOnly: false, cacheDirectory: cache)
        let t1 = mtime(p1)
        let p2 = try await ProxyMaker.proxy(for: m, ffmpeg: f, audioOnly: false, cacheDirectory: cache)
        #expect(p1 == p2 && mtime(p2) == t1)
        #expect(p1.path.hasPrefix(cache.path))
        #expect(try await MediaInfo.hasVideo(p1))
        let a = try await ProxyMaker.proxy(for: m, ffmpeg: f, audioOnly: true, cacheDirectory: cache)
        #expect(a.pathExtension == "m4a")
        #expect(try await !MediaInfo.hasVideo(a))
    }
}
