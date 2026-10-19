import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// The noisy test clips are slow to generate, so each kind is made once per test run (in a folder removed
/// when the process exits) and every test copies it into its own folder.
private actor SharedClips {
    static let shared = SharedClips()
    private var folder: URL?
    private var tasks: [String: Task<URL, Never>] = [:]

    func template(_ key: String, make: @escaping @Sendable (URL) async -> URL) -> Task<URL, Never> {
        if let task = tasks[key] { return task }
        let dir = folder ?? Self.makeFolder()
        folder = dir
        let task = Task { await make(dir) }
        tasks[key] = task
        return task
    }

    private static func makeFolder() -> URL {
        let dir = Fixtures.tempDir()
        SharedClipsCleanup.folder = dir
        atexit { if let dir = SharedClipsCleanup.folder { try? FileManager.default.removeItem(at: dir) } }
        return dir
    }

    /// A copy of the clip called `key` (made by `make` the first time), named `name` in `directory`.
    static func copy(_ key: String, as name: String, in directory: URL, make: @escaping @Sendable (URL) async -> URL) async -> URL {
        let template = await shared.template(key, make: make).value
        let destination = directory.appending(path: name, directoryHint: .notDirectory)
        do { try FileManager.default.copyItem(at: template, to: destination) } catch { preconditionFailure("SharedClips: \(error)") }
        return destination
    }
}

private enum SharedClipsCleanup {
    nonisolated(unsafe) static var folder: URL?
}

@Suite final class VideoToolTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    var ff: FFmpeg { FFmpeg(executable: Fixtures.ffmpeg!) }

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    // MARK: Helpers

    private func runner(_ caps: Capabilities) -> JobRunner {
        let rootPath = root.path + "/"
        return JobRunner(
            processors: ProcessorRegistry.standard(capabilities: caps), capabilities: caps, fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
    }

    /// A 3 s, 640×480 video with audio and noise.
    private func makeClip(_ name: String = "clip.mov") async -> URL {
        await SharedClips.copy("clip", as: name, in: root) { dir in
            await Fixtures.video("clip.mov", seconds: 3, w: 640, h: 480, noise: true, in: dir)
        }
    }

    private func makeClipRotated() async -> URL {
        await SharedClips.copy("rotated", as: "rot.mov", in: root) { dir in
            await Fixtures.video("rot.mov", seconds: 3, w: 640, h: 480, noise: true, rotated: true, in: dir)
        }
    }

    private func makeSmall320() async -> URL {
        await Fixtures.video("small.mov", seconds: 3, w: 320, h: 240, in: root)
    }

    private func toolResult(_ src: URL, _ id: ToolID, _ parameters: ToolParameters = .none, preset: Preset? = nil,
                            caps: Capabilities = Fixtures.caps) async throws -> JobResult {
        try await toolMultiResult([src], id, parameters, preset: preset, caps: caps)
    }

    private func toolMultiResult(_ srcs: [URL], _ id: ToolID, _ parameters: ToolParameters = .none, preset: Preset? = nil,
                                 caps: Capabilities = Fixtures.caps) async throws -> JobResult {
        let request = JobRequest(items: srcs.map(DroppedItem.init(url:)), action: .tool(id, preset), parameters: parameters)
        let result = try await runner(caps).run(request, progress: { _ in })
        if let failure = result.failures.first { throw OrbitError.unsupported(failure.message) }
        return result
    }

    private func tool(_ src: URL, _ id: ToolID, _ parameters: ToolParameters = .none, preset: Preset? = nil,
                      caps: Capabilities = Fixtures.caps) async throws -> URL {
        try await toolResult(src, id, parameters, preset: preset, caps: caps).outputs[0]
    }

    private func toolMulti(_ srcs: [URL], _ id: ToolID, caps: Capabilities = Fixtures.caps) async throws -> URL {
        try await toolMultiResult(srcs, id, caps: caps).outputs[0]
    }

    private func dur(_ url: URL) async throws -> Double { try await MediaInfo.duration(url) }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    // MARK: Bitrate plan

    @Test func bitratePlan() {
        #expect(VideoBitrate.plan(durationSeconds: 60, targetBytes: 10_000_000, sourceHeight: 1080, hasAudio: true)
            == .init(videoKbps: 1138, audioKbps: 128, maxHeight: 720))
        #expect(VideoBitrate.plan(durationSeconds: 10, targetBytes: 100_000, sourceHeight: 1080, hasAudio: true) == nil)
        #expect(VideoBitrate.plan(durationSeconds: 30, targetBytes: 50_000_000, sourceHeight: 720, hasAudio: false)
            == .init(videoKbps: 12666, audioKbps: 0, maxHeight: nil))
    }

    @Test func bitratePlanHeightTiers() {
        // total 736 kbps -> audio 64, video 672: not under 600, so 720 (when the source is taller).
        #expect(VideoBitrate.plan(durationSeconds: 100, targetBytes: 9_700_000, sourceHeight: 2160, hasAudio: true)?.maxHeight == 720)
        // total 500 -> audio 64, video 436: 480.
        #expect(VideoBitrate.plan(durationSeconds: 100, targetBytes: 6_600_000, sourceHeight: 1080, hasAudio: true)?.maxHeight == 480)
        // video ~3000: 1080; a 1080 source is not shrunk.
        #expect(VideoBitrate.plan(durationSeconds: 100, targetBytes: 40_000_000, sourceHeight: 2160, hasAudio: true)?.maxHeight == 1080)
        #expect(VideoBitrate.plan(durationSeconds: 100, targetBytes: 40_000_000, sourceHeight: 1080, hasAudio: true)?.maxHeight == nil)
        // video 8000+: never scaled.
        #expect(VideoBitrate.plan(durationSeconds: 100, targetBytes: 100_000_000, sourceHeight: 2160, hasAudio: true)?.maxHeight == nil)
        // Degenerate input.
        #expect(VideoBitrate.plan(durationSeconds: 0, targetBytes: 1_000_000, sourceHeight: 480, hasAudio: true) == nil)
    }

    // MARK: Native tools

    @Test func trim() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .trim, .timeRange(0.5...1.5))
        #expect(abs(try await dur(o) - 1) < 0.1)
        #expect(o.lastPathComponent == "clip-trimmed.mov")
        #expect(try await MediaInfo.hasAudio(o))
    }

    @Test func trimNeedsARangeInsideTheVideo() async throws {
        let clip = await makeClip()
        await #expect(throws: OrbitError.self) { _ = try await self.tool(clip, .trim) }
        await #expect(throws: OrbitError.self) { _ = try await self.tool(clip, .trim, .timeRange(5...6)) }
    }

    @Test func crop() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .crop, .cropRect(.init(x: 0, y: 0, width: 320, height: 240)))
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 320, height: 240))
        #expect(abs(try await dur(o) - 3) < 0.2)
    }

    @Test func cropRotated() async throws {
        let clipRotated = await makeClipRotated()
        let o = try await tool(clipRotated, .crop, .cropRect(.init(x: 0, y: 0, width: 240, height: 320)))
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 240, height: 320))
    }

    @Test func speed2() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .speed, preset: .speed(2))
        #expect(abs(try await dur(o) - 1.5) < 0.15)
        #expect(try await MediaInfo.hasAudio(o))
        #expect(o.lastPathComponent == "clip-2x.mov")
    }

    @Test func speed4DropsAudio() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .speed, preset: .speed(4))
        #expect(abs(try await dur(o) - 0.75) < 0.1)
        #expect(!(try await MediaInfo.hasAudio(o)))
    }

    @Test func slowMotionStretchesAndKeepsAudioAtHalf() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .speed, preset: .speed(0.5))
        #expect(abs(try await dur(o) - 6) < 0.3)
        #expect(try await MediaInfo.hasAudio(o))
    }

    @Test func speedRejectsNonsense() async throws {
        let clip = await makeClip()
        await #expect(throws: OrbitError.self) { _ = try await self.tool(clip, .speed, preset: .speed(0)) }
        await #expect(throws: OrbitError.self) { _ = try await self.tool(clip, .speed) }
    }

    @Test func split() async throws {
        let clip = await makeClip()
        let r = try await toolResult(clip, .split, .splitPoints([1, 2]))
        #expect(r.outputs.map(\.lastPathComponent) == ["clip-part-1.mov", "clip-part-2.mov", "clip-part-3.mov"])
        for o in r.outputs { #expect(abs(try await dur(o) - 1) < 0.15) }
    }

    @Test func splitRejectsPointsOutsideTheVideo() async throws {
        let clip = await makeClip()
        await #expect(throws: OrbitError.self) { _ = try await self.toolResult(clip, .split, .splitPoints([5])) }
        await #expect(throws: OrbitError.self) { _ = try await self.toolResult(clip, .split, .splitPoints([])) }
        await #expect(throws: OrbitError.self) { _ = try await self.toolResult(clip, .split, .splitPoints([2, 1])) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("part") }.isEmpty)
    }

    @Test func snapshot() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .snapshot, .time(1))
        #expect(Fixtures.size(o) == CGSize(width: 640, height: 480))
        #expect(o.lastPathComponent == "clip-snapshot.png")
        #expect(Fixtures.uti(o) == "public.png")
    }

    @Test func snapshotAtTheEndOfAVideo() async throws {
        let clipRotated = await makeClipRotated()
        let o = try await tool(clipRotated, .snapshot, .time(99))
        #expect(Fixtures.size(o) == CGSize(width: 640, height: 480))
    }

    @Test func mute() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .mute)
        #expect(!(try await MediaInfo.hasAudio(o)))
        #expect(try await MediaInfo.hasVideo(o))
        #expect(o.lastPathComponent == "clip-muted.mov")
        #expect(abs(try await dur(o) - 3) < 0.15)
    }

    @Test func muteKeepsTheOrientation() async throws {
        let clipRotated = await makeClipRotated()
        let o = try await tool(clipRotated, .mute)
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 640, height: 480))
    }

    @Test func removeMeta() async throws {
        let m = await Fixtures.video("m.mov", seconds: 1, w: 320, h: 240, metadata: ["make": "OrbitCam", "location": "+37.3300-122.0300/"], in: root)
        #expect(Fixtures.bytes(m).range(of: Data("OrbitCam".utf8)) != nil)
        let o = try await tool(m, .removeMetadata)
        #expect(Fixtures.bytes(o).range(of: Data("OrbitCam".utf8)) == nil)
        #expect(Fixtures.bytes(o).range(of: Data("+37.3300".utf8)) == nil)
        #expect(o.lastPathComponent == "m-clean.mov")
        #expect(try await MediaInfo.hasVideo(o))
        #expect(try await MediaInfo.hasAudio(o))
    }

    @Test func mixedSelectionStripAllBehavesLikeRemoveMeta() async throws {
        let m = await Fixtures.video("m2.mov", seconds: 1, w: 320, h: 240, metadata: ["make": "OrbitCam"], in: root)
        let o = try await tool(m, .metadata, preset: .metadataStripAll)
        #expect(Fixtures.bytes(o).range(of: Data("OrbitCam".utf8)) == nil)
        #expect(o.lastPathComponent == "m2-clean.mov")
    }

    @Test func joinMixedSizes() async throws {
        let clip = await makeClip(), small320 = await makeSmall320()
        let o = try await toolMulti([clip, small320], .join)
        #expect(abs(try await dur(o) - 6) < 0.2)
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 640, height: 480))
        #expect(o.lastPathComponent == "clip-joined.mov")
        #expect(try await MediaInfo.hasAudio(o))
    }

    @Test func joinSameSizes() async throws {
        let a = await Fixtures.video("a.mov", seconds: 1, w: 320, h: 240, in: root)
        let b = await Fixtures.video("b.mov", seconds: 2, w: 320, h: 240, in: root)
        let o = try await toolMulti([a, b], .join)
        #expect(abs(try await dur(o) - 3) < 0.15)
        #expect(try await MediaInfo.videoSize(o) == CGSize(width: 320, height: 240))
    }

    @Test func compressFits() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .compress, preset: .compress(.fitUnder(500_000)))
        #expect(try fileSize(o) <= 500_000)
        #expect(abs(try await dur(o) - 3) < 0.2)
        #expect(try await MediaInfo.hasAudio(o))
        #expect(o.lastPathComponent == "clip-compressed.mov")
    }

    @Test func compressImpossible() async throws {
        let clip = await makeClip()
        await #expect(throws: OrbitError.targetTooSmall("Can't fit this video under 5 KB.")) {
            _ = try await self.tool(clip, .compress, preset: .compress(.fitUnder(5_000)))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("compressed") }.isEmpty)
    }

    @Test func compressTierTargetsAFractionOfTheSource() async throws {
        let clip = await makeClip()
        let before = try fileSize(clip)
        let o = try await tool(clip, .compress, preset: .compress(.tier(.medium)))
        #expect(try fileSize(o) <= Int(Double(before) * 0.5))
    }

    @Test func compressViaEditorParameters() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .compress, .compress(.fitUnder(600_000)))
        #expect(try fileSize(o) <= 600_000)
    }

    @Test func compressReportsSizes() async throws {
        let clip = await makeClip()
        let r = try await toolResult(clip, .compress, preset: .compress(.fitUnder(500_000)))
        #expect(r.summary.contains("→"))
    }

    @Test func sourcesAreNeverTouched() async throws {
        let clip = await makeClip()
        let before = Fixtures.bytes(clip)
        _ = try await tool(clip, .trim, .timeRange(0...1))
        _ = try await tool(clip, .mute)
        _ = try await tool(clip, .removeMetadata)
        #expect(Fixtures.bytes(clip) == before)
    }

    @Test(arguments: [0, 20, 60])
    func cancellingCompressLeavesNothingBehind(delayMilliseconds: Int) async throws {
        let clip = await makeClip()
        let task = Task { try await self.tool(clip, .compress, preset: .compress(.fitUnder(500_000))) }
        try await Task.sleep(for: .milliseconds(delayMilliseconds))
        task.cancel()
        // The encode may win the race; only a cancelled job has to leave nothing behind.
        if case .failure = await task.result {
            let stray = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("compressed") }
            #expect(stray.isEmpty)
        }
    }

    // MARK: ffmpeg path

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func trimMKVStaysMKV() async throws {
        let o = try await tool(await Fixtures.mkv(seconds: 3, in: root), .trim, .timeRange(0.5...1.5))
        #expect(o.pathExtension == "mkv")
        let seconds = try await ff.duration(of: o)
        #expect(abs(seconds - 1) < 0.15, "trimmed MKV is \(seconds) s long")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func muteMKV() async throws {
        let o = try await tool(await Fixtures.mkv(seconds: 2, in: root), .mute)
        let facts = await Fixtures.streamFacts(o)
        #expect(!facts.hasAudio)
        #expect(facts.videoSize == CGSize(width: 320, height: 240))
        #expect(o.lastPathComponent == "clip-muted.mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func removeMetaMKV() async throws {
        let src = await Fixtures.mkv(seconds: 2, in: root)
        let tagged = root.appending(path: "tagged.mkv")
        try await ff.run(inputs: [src], args: ["-c", "copy", "-metadata", "title=OrbitSecretTitle"], output: tagged, duration: nil, progress: { _ in })
        #expect(Fixtures.bytes(tagged).range(of: Data("OrbitSecretTitle".utf8)) != nil)
        let o = try await tool(tagged, .removeMetadata)
        #expect(Fixtures.bytes(o).range(of: Data("OrbitSecretTitle".utf8)) == nil)
        #expect(o.pathExtension == "mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func speedMKV() async throws {
        let src = await Fixtures.mkv(seconds: 3, in: root)
        let fast = try await tool(src, .speed, preset: .speed(2))
        let f = await Fixtures.streamFacts(fast)
        #expect(abs(f.duration - 1.5) < 0.25)
        #expect(f.hasAudio)
        // 4x chains atempo and keeps the audio on this path.
        let faster = try await tool(src, .speed, preset: .speed(4))
        let g = await Fixtures.streamFacts(faster)
        #expect(abs(g.duration - 0.75) < 0.25)
        #expect(g.hasAudio)
        #expect(faster.pathExtension == "mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func cropMKV() async throws {
        let o = try await tool(await Fixtures.mkv(seconds: 2, in: root), .crop, .cropRect(.init(x: 10, y: 20, width: 160, height: 120)))
        let facts = await Fixtures.streamFacts(o)
        #expect(facts.videoSize == CGSize(width: 160, height: 120))
        #expect(o.pathExtension == "mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func snapshotMKV() async throws {
        let o = try await tool(await Fixtures.mkv(seconds: 2, in: root), .snapshot, .time(1))
        #expect(Fixtures.size(o) == CGSize(width: 320, height: 240))
        #expect(o.pathExtension == "png")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func splitMKV() async throws {
        let r = try await toolResult(await Fixtures.mkv(seconds: 3, in: root), .split, .splitPoints([1, 2]))
        #expect(r.outputs.map(\.lastPathComponent) == ["clip-part-1.mkv", "clip-part-2.mkv", "clip-part-3.mkv"])
        var total = 0.0
        for o in r.outputs { total += await Fixtures.streamFacts(o).duration }
        #expect(abs(total - 3) < 0.4)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func joinMKVs() async throws {
        let a = await Fixtures.mkv(named: "a.mkv", seconds: 1, in: root)
        let b = await Fixtures.mkv(named: "b.mkv", seconds: 2, in: root)
        let o = try await toolMulti([a, b], .join)
        let facts = await Fixtures.streamFacts(o)
        #expect(abs(facts.duration - 3) < 0.25)
        #expect(o.lastPathComponent == "a-joined.mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func joinMKVsOfDifferentSizesScalesToTheFirst() async throws {
        let a = await Fixtures.mkv(named: "a.mkv", seconds: 1, in: root)
        let b = await Fixtures.mkv(named: "b.mkv", seconds: 1, w: 160, h: 120, in: root)
        let o = try await toolMulti([a, b], .join)
        let facts = await Fixtures.streamFacts(o)
        #expect(facts.videoSize == CGSize(width: 320, height: 240))
        #expect(abs(facts.duration - 2) < 0.3)
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func compressMKV() async throws {
        let src = await Fixtures.video("big.mov", seconds: 3, w: 640, h: 480, noise: true, in: root)
        let mkv = root.appending(path: "big.mkv")
        try await ff.run(inputs: [src], args: ["-c", "copy"], output: mkv, duration: nil, progress: { _ in })
        let o = try await tool(mkv, .compress, preset: .compress(.fitUnder(500_000)))
        #expect(try fileSize(o) <= 500_000)
        #expect(o.pathExtension == "mkv")
    }

    @Test(.enabled(if: Fixtures.hasFFmpeg)) func unsafeFileNamesWorkWithFFmpeg() async throws {
        let src = await Fixtures.mkv(named: "-rf 'q\" ü.mkv", seconds: 2, in: root)
        let o = try await tool(src, .trim, .timeRange(0...1))
        #expect(o.lastPathComponent == "-rf 'q\" ü-trimmed.mkv")
        #expect(abs(try await ff.duration(of: o) - 1) < 0.2)
        let joined = try await toolMulti([src, src], .join)
        #expect(abs(await Fixtures.streamFacts(joined).duration - 4) < 0.3)
    }

    @Test func atempoChainsStayInsideTheFilterRange() {
        #expect(VideoToolsFFmpeg.atempoChain(2) == ["atempo=2"])
        #expect(VideoToolsFFmpeg.atempoChain(4) == ["atempo=2", "atempo=2"])
        #expect(VideoToolsFFmpeg.atempoChain(0.25) == ["atempo=0.5", "atempo=0.5"])
        #expect(VideoToolsFFmpeg.atempoChain(8) == ["atempo=2", "atempo=2", "atempo=2"])
        #expect(VideoToolsFFmpeg.atempoChain(1.5) == ["atempo=1.5"])
    }

    @Test func ffmpegOnlyToolsWithoutFFmpegSayWhy() async throws {
        let mkv = Fixtures.file("a.mkv", "not really a video", in: root)
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { _ = try await self.tool(mkv, .trim, .timeRange(0...1), caps: Capabilities()) }
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { _ = try await self.tool(mkv, .mute, caps: Capabilities()) }
        await #expect(throws: OrbitError.helperMissing(.ffmpeg)) { _ = try await self.toolMulti([mkv, mkv], .join, caps: Capabilities()) }
        let stray = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.contains("trimmed") || $0.contains("muted") || $0.contains("joined") }
        #expect(stray.isEmpty)
    }

    @Test func nativeToolsWorkWithoutFFmpeg() async throws {
        let clip = await makeClip()
        let o = try await tool(clip, .mute, caps: Capabilities())
        #expect(!(try await MediaInfo.hasAudio(o)))
    }
}
