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
        #expect(GIFMaker.plan(duration: GIFMaker.maxDuration + 1, fps: 12) == nil)
    }

    @Test func movToM4A() async throws {
        let o = try await run(await clip(), .convert(.m4a)).outputs[0]
        #expect(try await !MediaInfo.hasVideo(o))
        #expect(abs(try await MediaInfo.duration(o) - 2) < 0.1)
    }

    @Test func mediaInfoReadsRotationAndChannels() async throws {
        let rotated = await Fixtures.video("r.mov", seconds: 1, w: 320, h: 240, rotated: true, in: root)
        #expect(try await MediaInfo.videoSize(rotated) == CGSize(width: 320, height: 240))
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
