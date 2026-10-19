import AppKit
import OrbitCore
import SwiftUI

/// The media editors' part of `--check-editors` (see `EditorCheck`). Sample media is written by ffmpeg to a fresh temporary
/// folder, which is removed afterwards.
extension EditorCheck {
    private struct Samples {
        let folder: URL
        let ffmpeg: FFmpeg
        let video: URL    // 1920x1080, 25 fps, 4 s, with sound
        let audio: URL    // 6 s of an amplitude-modulated tone
        let mkv: URL      // the video, copied into Matroska
    }

    @MainActor
    static func runMediaEditors(check: Checker) {
        guard let ffmpegURL = HelperLocator().locate(customFFmpegPath: nil).ffmpeg else {
            return check.skip("media editors", "ffmpeg isn't installed, so there are no sample files")
        }
        guard let samples = makeSamples(FFmpeg(executable: ffmpegURL)) else {
            return check("write the sample media", false)
        }
        defer { try? FileManager.default.removeItem(at: samples.folder) }

        checkVideoSession(samples, check)
        checkAudioSession(samples, check)
        checkProxySession(samples, check)
        checkProxyProbe(samples, check)
        checkClosingStopsTheProxyLoad(samples, check)
        checkRangeModel(samples, check)
        checkCropModel(samples, check)
        checkPanels(samples, check)
        checkPanelHeights(samples, check)
        checkAudioMetadataLoader(samples, check)
    }

    // MARK: Samples

    private static func makeSamples(_ ffmpeg: FFmpeg) -> Samples? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-media-check-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else { return nil }
        let video = folder.appendingPathComponent("clip.mov"), audio = folder.appendingPathComponent("tone.m4a")
        let mkv = folder.appendingPathComponent("clip.mkv")
        func run(_ args: [String]) -> Bool {
            let process = Process()
            process.executableURL = ffmpeg.executable
            process.arguments = ["-hide_banner", "-nostdin", "-loglevel", "error"] + args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        let ok = run(["-f", "lavfi", "-i", "testsrc2=size=1920x1080:rate=25", "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=44100",
                      "-t", "4", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", video.path])
            && run(["-f", "lavfi", "-i", "aevalsrc=sin(2*PI*440*t)*abs(sin(2*PI*0.7*t)):s=44100:d=6", "-c:a", "aac", audio.path])
            && run(["-i", video.path, "-c", "copy", mkv.path])
        guard ok else {
            try? FileManager.default.removeItem(at: folder)
            return nil
        }
        return Samples(folder: folder, ffmpeg: ffmpeg, video: video, audio: audio, mkv: mkv)
    }

    @MainActor
    private static func loaded(_ session: MediaSession) -> Bool {
        var done = false
        Task { await session.load(); done = true }
        spin(until: { done }, timeout: 60)
        return done && session.isReady
    }

    private static func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.01) -> Bool { abs(a - b) <= tolerance }

    // MARK: Sessions

    @MainActor
    private static func checkVideoSession(_ samples: Samples, _ check: Checker) {
        let session = MediaSession(item: DroppedItem(url: samples.video), ffmpeg: samples.ffmpeg)
        session.generatesStills = true
        check("session (video): opens", loaded(session), "\(session.status)")
        check("session (video): duration, size and frame rate come from the file",
              near(session.duration, 4, 0.1) && session.videoSize == CGSize(width: 1920, height: 1080) && near(session.frameRate, 25, 0.5),
              "\(session.duration) s, \(String(describing: session.videoSize)), \(session.frameRate) fps")
        check("session (video): a step is one frame", near(session.stepSize, 0.04))
        session.step(1)
        check("session (video): |> moves one frame on", near(session.playhead, 0.04), "\(session.playhead)")
        session.step(-1)
        session.step(-1)
        check("session (video): <| stops at the first frame", session.playhead == 0, "\(session.playhead)")
        session.seek(to: 99)
        check("session (video): seeking past the end stops at the last frame", near(session.playhead, session.duration - 0.04, 0.02),
              "\(session.playhead)")
        session.seek(to: 2)
        spin(until: { false }, timeout: 1)
        check("session (video): a still of the frame at the playhead is made", session.still != nil)

        session.seek(to: 0)
        session.togglePlay()
        spin(until: { session.playhead > 0.3 }, timeout: 5)
        check("session (video): play advances the playhead", session.isPlaying && session.playhead > 0.3, "\(session.playhead)")
        session.togglePlay()
        spin(until: { !session.isPlaying }, timeout: 2)
        check("session (video): pause stops it", !session.isPlaying)

        session.playbackWindow = 1...1.5
        session.seek(to: 3)
        session.togglePlay()
        check("session (video): play from outside the window starts at its beginning", near(session.playhead, 1, 0.05), "\(session.playhead)")
        spin(until: { session.isPlaying }, timeout: 2)
        spin(until: { !session.isPlaying }, timeout: 5)
        check("session (video): play stops at the end of the window", !session.isPlaying && near(session.playhead, 1.5, 0.08),
              "\(session.playhead)")
        session.stop()
        check("session (video): stop releases the player", session.player == nil && !session.isPlaying)
    }

    @MainActor
    private static func checkAudioSession(_ samples: Samples, _ check: Checker) {
        let session = MediaSession(item: DroppedItem(url: samples.audio), ffmpeg: samples.ffmpeg)
        check("session (audio): opens", loaded(session), "\(session.status)")
        check("session (audio): duration, no picture, a waveform",
              near(session.duration, 6, 0.1) && session.videoSize == nil && session.peaks.count == 480
                  && (session.peaks.max() ?? 0) > 0.3, "\(session.duration) s, \(session.peaks.count) peaks")
        session.step(1)
        session.step(1)
        check("session (audio): a step is a tenth of a second", near(session.playhead, 0.2), "\(session.playhead)")
        session.seek(to: 99)
        check("session (audio): seeking past the end stops at the end", near(session.playhead, session.duration), "\(session.playhead)")
        session.stop()
    }

    /// An MKV can't be opened by AVFoundation: the session previews a proxy but measures the original.
    @MainActor
    private static func checkProxySession(_ samples: Samples, _ check: Checker) {
        let item = DroppedItem(url: samples.mkv)
        check("proxy: the MKV needs ffmpeg to be read", MediaSupport.needsFFmpegToRead(item))

        let session = MediaSession(item: item, ffmpeg: samples.ffmpeg)
        // `ProxyMaker` uses the hardware encoder, which may be unavailable where this runs: make the proxy in software.
        let folder = samples.folder
        let made = Box<Bool?>(nil)
        session.proxyProvider = { url, ffmpeg, audioOnly in
            let out = folder.appendingPathComponent("proxy-\(UUID().uuidString).\(audioOnly ? "m4a" : "mp4")")
            try await ffmpeg.run(inputs: [url], args: audioOnly ? ["-vn", "-c:a", "aac"]
                                 : ["-c:v", "libx264", "-pix_fmt", "yuv420p", "-vf", "scale='min(640,iw)':-2", "-c:a", "aac"],
                                 output: out, duration: nil, progress: { _ in })
            await MainActor.run { made.value = audioOnly }
            return out
        }
        check("proxy: the editor opens an MKV through a preview proxy", loaded(session) && made.value == false, "\(session.status)")
        check("proxy: the size is the original's (1920x1080), not the 640 px proxy's",
              session.videoSize == CGSize(width: 1920, height: 1080), "\(String(describing: session.videoSize))")
        check("proxy: the duration and a player come from the proxy", near(session.duration, 4, 0.15) && session.player != nil)
        session.stop()

        let without = MediaSession(item: item, ffmpeg: nil)
        _ = loaded(without)
        if case .failed(let message) = without.status {
            check("proxy: an MKV without ffmpeg says so", message.contains("ffmpeg"), message)
        } else {
            check("proxy: an MKV without ffmpeg fails", false, "\(without.status)")
        }
    }


    /// A proxied video whose original can't be probed has no picture size to measure a crop in, and the proxy's (at most
    /// 1280 px wide) must never stand in for it.
    @MainActor
    private static func checkProxyProbe(_ samples: Samples, _ check: Checker) {
        func attempt(_ name: String, says expected: String, probe: @escaping @Sendable (URL, FFmpeg) async throws -> MediaProbe.VideoStream?) {
            let session = MediaSession(item: DroppedItem(url: samples.mkv), ffmpeg: samples.ffmpeg)
            let tally = Tally()
            session.videoProbe = probe
            session.proxyProvider = { _, _, _ in
                tally.add("proxy")
                return samples.video   // a real, smaller-or-equal file: the old code would have adopted its size
            }
            let opened = loaded(session)
            var message = ""
            if case .failed(let text) = session.status { message = text }
            check("proxy probe (\(name)): the editor refuses instead of opening", !opened && !message.isEmpty, "\(session.status)")
            check("proxy probe (\(name)): it says why, and keeps no size",
                  session.videoSize == nil && message.contains(expected), "\(message), \(String(describing: session.videoSize))")
            check("proxy probe (\(name)): no preview was encoded for a file that can't be edited", tally.count("proxy") == 0)
            session.stop()
        }
        attempt("nothing listed", says: "picture size") { _, _ in nil }
        attempt("ffmpeg can't run", says: "could not be started") { _, _ in throw OrbitError.unsupported("ffmpeg could not be started") }
    }


    /// Closing the panel while "Preparing a preview…" runs must stop the encode, quietly, and reopening must not start a
    /// second one beside it. A `sleep` stands in for the ffmpeg encode (same `ProcessRunner`, same cancellation).
    @MainActor
    private static func checkClosingStopsTheProxyLoad(_ samples: Samples, _ check: Checker) {
        let marker = "31.\(Int.random(in: 100...999))"
        let tally = Tally()
        func makeSession(_ item: DroppedItem) -> MediaSession {
            let session = MediaSession(item: item, ffmpeg: samples.ffmpeg)
            session.proxyProvider = { _, _, _ in
                tally.add("started")
                tally.add("running")
                defer { tally.add("running", -1) }
                do {
                    _ = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), [marker])
                } catch {
                    tally.add("ended-by-error")
                    throw error
                }
                return samples.video
            }
            return session
        }
        let host = EditorRouter.MediaHost(ffmpeg: samples.ffmpeg, options: { JobOptions() }, submit: { _ in }, makeSession: makeSession)
        let mkv = [DroppedItem(url: samples.mkv)]

        for (name, open) in [("crop", { EditorRouter.openVideoCrop(mkv, action: .tool(.crop, nil), host: host) }),
                             ("trim", { EditorRouter.openMediaRange(mkv, mode: .trim, action: .tool(.trim, nil), host: host) })]
            as [(String, () -> EditorWindowController?)] {
            tally.reset()
            guard let controller = open() else { check("close during a proxy load (\(name)): opens", false); continue }
            spin(until: { tally.count("started") == 1 }, timeout: 10)
            check("close during a proxy load (\(name)): the preview encode is running", tally.count("started") == 1 && runningCount(marker) == 1,
                  "\(tally.count("started")) started, \(runningCount(marker)) processes")
            controller.close()
            spin(until: { tally.count("running") == 0 && runningCount(marker) == 0 }, timeout: 8)
            check("close during a proxy load (\(name)): the encode is stopped", tally.count("ended-by-error") == 1 && runningCount(marker) == 0,
                  "\(tally.count("ended-by-error")) cancelled, \(runningCount(marker)) processes left")

            // Reopening starts one encode, not two side by side.
            guard let again = open() else { check("close during a proxy load (\(name)): reopens", false); continue }
            spin(until: { tally.count("started") == 2 }, timeout: 10)
            check("close during a proxy load (\(name)): reopening runs exactly one encode",
                  tally.count("started") == 2 && runningCount(marker) == 1, "\(tally.count("started")) started, \(runningCount(marker)) processes")
            again.close()
            spin(until: { runningCount(marker) == 0 }, timeout: 8)
            check("close during a proxy load (\(name)): and it stops too", runningCount(marker) == 0)
            settle()
        }

        // The cancelled load is a quiet exit, not an error shown to nobody.
        let session = makeSession(DroppedItem(url: samples.mkv))
        var finished = false
        Task { await session.load(); finished = true }
        spin(until: { tally.count("running") == 1 }, timeout: 10)
        session.stop()
        spin(until: { finished }, timeout: 8)
        var failed = false
        if case .failed = session.status { failed = true }
        check("close during a proxy load: load() returns without a failure status", finished && !failed && !session.isReady, "\(session.status)")
        check("close during a proxy load: nothing is left running", runningCount(marker) == 0)
    }

    /// How many `sleep <marker>` processes are alive (read-only `pgrep`).
    private static func runningCount(_ marker: String) -> Int {
        let process = Process(), out = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-f", "sleep \(marker)"]
        process.standardOutput = out
        guard (try? process.run()) != nil else { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).count
    }

    /// Named counters the `@Sendable` stand-ins bump from any thread.
    private final class Tally: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [String: Int] = [:]
        func add(_ key: String, _ amount: Int = 1) { lock.lock(); counts[key, default: 0] += amount; lock.unlock() }
        func count(_ key: String) -> Int { lock.lock(); defer { lock.unlock() }; return counts[key, default: 0] }
        func reset() { lock.lock(); counts = [:]; lock.unlock() }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }

    // MARK: Trim, Split, Snapshot, Bleep

    @MainActor
    private static func checkRangeModel(_ samples: Samples, _ check: Checker) {
        func model(_ mode: MediaEditMode, _ url: URL) -> MediaRangeModel {
            let session = MediaSession(item: DroppedItem(url: url), ffmpeg: samples.ffmpeg)
            let model = MediaRangeModel(session: session, mode: mode)
            var done = false
            Task { await model.load(); done = true }
            spin(until: { done }, timeout: 60)
            return model
        }

        // Trim
        let trim = model(.trim, samples.audio)
        let d = trim.duration
        check("trim: opens on the whole file, which is nothing to apply", trim.start == 0 && trim.end == d && trim.parameters == nil)
        trim.setStart(1)
        check("trim: a start handle gives the range to keep", trim.parameters == .timeRange(1...d), "\(String(describing: trim.parameters))")
        trim.setStart(d)
        check("trim: the start handle stops a step short of the end", near(trim.start, d - 0.1, 0.001), "\(trim.start)")
        trim.setEnd(0)
        check("trim: the end handle stops a step past the start", near(trim.end, trim.start + 0.1, 0.001), "\(trim.start)-\(trim.end)")
        trim.setStart(2)
        trim.setEnd(4)
        trim.session.seek(to: 3)
        trim.setEndToPlayhead()
        trim.session.seek(to: 2.5)
        trim.setStartToPlayhead()
        check("trim: Start here and End here take the playhead", trim.parameters == .timeRange(2.5...3), "\(String(describing: trim.parameters))")
        check("trim: playback is limited to the selection", trim.session.playbackWindow == 2.5...3)
        trim.session.stop()

        // Split
        let split = model(.split, samples.video)
        check("split: no markers, nothing to apply", split.parameters == nil)
        check("split: no marker at the first frame", !split.canAddMarker)
        split.session.seek(to: 3)
        split.addMarker()
        split.session.seek(to: 1)
        split.addMarker()
        split.addMarker()
        check("split: markers are kept in order, once each", split.markers == [1, 3], "\(split.markers)")
        check("split: markers give the split points", split.parameters == .splitPoints([1, 3]))
        split.removeMarker(at: 0)
        check("split: a marker can be removed", split.markers == [3])
        split.splitEvenly(into: 4)
        let quarter = split.duration / 4
        check("split: into 4 equal parts makes 3 cuts", split.markers.count == 3 && near(split.markers[0], quarter, 0.001)
              && near(split.markers[2], 3 * quarter, 0.001), "\(split.markers)")
        check("split: the summary counts the files", split.summary == "Makes 4 files", split.summary)
        split.session.stop()

        // Snapshot
        let snapshot = model(.snapshot, samples.video)
        snapshot.session.seek(to: 2)
        check("snapshot: the frame at the playhead is the parameter", snapshot.parameters == .time(2), "\(String(describing: snapshot.parameters))")
        snapshot.session.stop()

        // Bleep
        let bleep = model(.bleep, samples.audio)
        check("bleep: opens with a short selection and no ranges, so nothing to apply",
              bleep.end > bleep.start && bleep.end - bleep.start < bleep.duration / 2 && bleep.parameters == nil)
        bleep.setStart(1)
        bleep.setEnd(2)
        bleep.addRange()
        bleep.setStart(1.5)
        bleep.setEnd(3)
        bleep.addRange()
        bleep.setEnd(5.5)
        bleep.setStart(5)
        bleep.addRange()
        check("bleep: overlapping ranges are joined", bleep.ranges == [1...3, 5...5.5], "\(bleep.ranges)")
        check("bleep: the ranges are the parameters", bleep.parameters == .bleepRanges([1...3, 5...5.5]))
        check("bleep: touching ranges join and the result is sorted",
              MediaRangeModel.merged([4...5, 1...2, 2...3]) == [1...3, 4...5])
        bleep.removeRange(at: 0)
        check("bleep: a range can be removed", bleep.ranges == [5...5.5])
        bleep.session.stop()
    }

    // MARK: Crop

    @MainActor
    private static func checkCropModel(_ samples: Samples, _ check: Checker) {
        let session = MediaSession(item: DroppedItem(url: samples.video), ffmpeg: samples.ffmpeg)
        let crop = CropModel(session: session)
        var done = false
        Task { await crop.load(); done = true }
        spin(until: { done }, timeout: 60)
        let full = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        check("crop: opens on the whole frame, which is nothing to apply", crop.rect == full && crop.parameters == nil, "\(crop.rect)")

        crop.setAspect(VideoCropAspect.all[1])
        check("crop: 1:1 gives the largest centered square", crop.rect == CGRect(x: 420, y: 0, width: 1080, height: 1080), "\(crop.rect)")
        check("crop: the square is the parameter, in source pixels", crop.parameters == .cropRect(CGRect(x: 420, y: 0, width: 1080, height: 1080)))
        crop.setWidthPercent(50)
        check("crop: with a ratio kept, the Width slider drives both sides",
              crop.rect.width == 960 && crop.rect.height == 960, "\(crop.rect)")
        check("crop: the slider readouts follow", Int(crop.widthPercent.rounded()) == 50 && Int(crop.heightPercent.rounded()) == 89)
        crop.setAspect(VideoCropAspect.all[4])
        check("crop: 9:16 is a tall rectangle", crop.rect.height > crop.rect.width
              && abs(crop.rect.width / crop.rect.height - 9.0 / 16) < 0.01, "\(crop.rect)")
        check("crop: every side is a whole, even number of pixels",
              [crop.rect.minX, crop.rect.minY, crop.rect.width, crop.rect.height].allSatisfy { $0 == $0.rounded() && Int($0) % 2 == 0 })

        crop.reset()
        check("crop: Reset goes back to the whole frame and Freeform", crop.rect == full && crop.aspect == .free)
        crop.setHeightPercent(62)
        check("crop: the Height slider (Freeform) keeps the width", crop.rect.width == 1920 && crop.rect.height == 668, "\(crop.rect)")

        // Dragging, in video pixels: a corner resizes against the opposite one, the inside moves, the outside draws anew.
        crop.reset()
        crop.setHeightPercent(50)   // 1920 x 540 at y = 270
        crop.beginDrag(at: CGPoint(x: 1900, y: 800), handleRadius: 40)
        crop.updateDrag(to: CGPoint(x: 1000, y: 700))
        crop.endDrag()
        check("crop: dragging the bottom right corner moves only that corner", crop.rect == CGRect(x: 0, y: 270, width: 1000, height: 430), "\(crop.rect)")
        crop.beginDrag(at: CGPoint(x: 500, y: 500), handleRadius: 40)
        crop.updateDrag(to: CGPoint(x: 600, y: 550))
        crop.endDrag()
        check("crop: dragging inside moves the rectangle", crop.rect == CGRect(x: 100, y: 320, width: 1000, height: 430), "\(crop.rect)")
        crop.beginDrag(at: CGPoint(x: 600, y: 550), handleRadius: 40)
        crop.updateDrag(to: CGPoint(x: 5000, y: 5000))
        crop.endDrag()
        check("crop: moving never leaves the frame", crop.rect == CGRect(x: 920, y: 650, width: 1000, height: 430), "\(crop.rect)")
        crop.beginDrag(at: CGPoint(x: 10, y: 10), handleRadius: 40)
        crop.updateDrag(to: CGPoint(x: 410, y: 310))
        crop.endDrag()
        check("crop: dragging outside draws a new rectangle", crop.rect == CGRect(x: 10, y: 10, width: 400, height: 300), "\(crop.rect)")
        crop.setAspect(VideoCropAspect.all[3])
        crop.beginDrag(at: CGPoint(x: 1000, y: 600), handleRadius: 5)
        crop.updateDrag(to: CGPoint(x: 1900, y: 1070))
        crop.endDrag()
        check("crop: a new rectangle keeps the chosen ratio", abs(crop.rect.width / crop.rect.height - 16.0 / 9) < 0.02, "\(crop.rect)")

        // The view's points map to video pixels through EditorGeometry: a 400 x 225 preview of a 1920 x 1080 frame.
        crop.reset()
        let view = CGSize(width: 400, height: 225)
        let from = EditorGeometry.viewToImage(CGPoint(x: 100, y: 50), image: crop.size, view: view)
        let to = EditorGeometry.viewToImage(CGPoint(x: 300, y: 150), image: crop.size, view: view)
        crop.beginDrag(at: CGPoint(x: 0, y: 0), handleRadius: 1)   // the top left corner: resize against the bottom right one
        crop.updateDrag(to: from)
        crop.endDrag()
        crop.beginDrag(at: CGPoint(x: 1920, y: 1080), handleRadius: 1)
        crop.updateDrag(to: to)
        crop.endDrag()
        check("crop: a drag in the preview is the matching rectangle in video pixels",
              crop.rect == CGRect(x: 480, y: 240, width: 960, height: 480), "\(crop.rect)")
        session.stop()
    }

    // MARK: Panels

    @MainActor
    private static func checkPanels(_ samples: Samples, _ check: Checker) {
        var requests: [JobRequest] = []
        let host = EditorRouter.MediaHost(ffmpeg: samples.ffmpeg, options: { JobOptions() }, submit: { requests.append($0) })
        func opens(_ name: String, _ open: () -> EditorWindowController?) {
            weak var released: EditorWindowController?
            autoreleasepool {
                guard let controller = open() else { return check("\(name): the router opens it", false) }
                released = controller
                spin(until: { false }, timeout: 1.5)
                checkPanel(name, controller, check)
                controller.close()
            }
            settle()
            check("\(name) controller released after close", released == nil)
        }
        let video = [DroppedItem(url: samples.video)], audio = [DroppedItem(url: samples.audio)]
        opens("trim (video)") { EditorRouter.openMediaRange(video, mode: .trim, action: .tool(.trim, nil), host: host) }
        opens("trim (audio)") { EditorRouter.openMediaRange(audio, mode: .trim, action: .tool(.trim, nil), host: host) }
        opens("split (video)") { EditorRouter.openMediaRange(video, mode: .split, action: .tool(.split, nil), host: host) }
        opens("snapshot") { EditorRouter.openMediaRange(video, mode: .snapshot, action: .tool(.snapshot, nil), host: host) }
        opens("bleep") { EditorRouter.openMediaRange(audio, mode: .bleep, action: .tool(.bleep, nil), host: host) }
        opens("crop") { EditorRouter.openVideoCrop(video, action: .tool(.crop, nil), host: host) }
        check("bleep: refuses a video", EditorRouter.openMediaRange(video, mode: .bleep, action: .tool(.bleep, nil), host: host) == nil)
        check("snapshot: refuses audio", EditorRouter.openMediaRange(audio, mode: .snapshot, action: .tool(.snapshot, nil), host: host) == nil)
        check("crop: refuses audio", EditorRouter.openVideoCrop(audio, action: .tool(.crop, nil), host: host) == nil)
        check("nothing was submitted by opening and closing", requests.isEmpty)
    }

    /// The panel is sized once, when it opens, from what it shows then (a spinner); what it shows once the file has loaded,
    /// or after chips are added, must not be taller or shorter, or it would be clipped or float.
    @MainActor
    private static func checkPanelHeights(_ samples: Samples, _ check: Checker) {
        func height<V: View>(_ view: V, _ width: CGFloat) -> CGFloat { NSHostingView(rootView: view.frame(width: width)).fittingSize.height }

        for (name, mode, url) in [("trim video", MediaEditMode.trim, samples.video), ("split audio", .split, samples.audio),
                                  ("bleep audio", .bleep, samples.audio), ("snapshot video", .snapshot, samples.video)] {
            let session = MediaSession(item: DroppedItem(url: url), ffmpeg: samples.ffmpeg)
            let model = MediaRangeModel(session: session, mode: mode)
            func editor() -> MediaRangeEditor { MediaRangeEditor(title: "T", model: model, onClose: {}, onApply: { _ in }) }
            let opening = height(editor(), MediaRangeEditor.width)
            var done = false
            Task { await model.load(); done = true }
            spin(until: { done }, timeout: 60)
            let ready = height(editor(), MediaRangeEditor.width)
            for t in stride(from: 0.5, through: 5.5, by: 0.5) {
                session.seek(to: t)
                model.addMarker()
                model.setEnd(t + 0.3)
                model.setStart(t)
                model.addRange()
            }
            let full = height(editor(), MediaRangeEditor.width)
            check("\(name): the panel keeps its height from opening to loaded to full of chips",
                  abs(opening - ready) < 1 && abs(ready - full) < 1, "\(opening), \(ready), \(full)")
            session.stop()
        }

        let session = MediaSession(item: DroppedItem(url: samples.video), ffmpeg: samples.ffmpeg)
        let crop = CropModel(session: session)
        func editor() -> VideoCropEditor { VideoCropEditor(title: "Crop Video", model: crop, onClose: {}, onApply: { _ in }) }
        let opening = height(editor(), VideoCropEditor.width)
        var done = false
        Task { await crop.load(); done = true }
        spin(until: { done }, timeout: 60)
        crop.setAspect(VideoCropAspect.all[1])
        check("crop: the panel keeps its height from opening to loaded", abs(opening - height(editor(), VideoCropEditor.width)) < 1,
              "\(opening), \(height(editor(), VideoCropEditor.width))")
        session.stop()
    }

    @MainActor
    private static func checkAudioMetadataLoader(_ samples: Samples, _ check: Checker) {
        guard let loader = EditorRouter.audioMetadataLoader else { return check("audio metadata: the router has a loader", false) }
        var fields: [MetadataField]?
        Task { fields = await loader(samples.audio, samples.ffmpeg) }
        spin(until: { fields != nil }, timeout: 20)
        check("audio metadata: the router's loader reads an audio file's fields", !(fields ?? []).isEmpty, "\(fields?.count ?? -1) fields")
    }
}
