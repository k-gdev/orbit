import AVFoundation
import Combine
import OrbitCore
import SwiftUI

/// One audio or video file opened for the media editors: what the editors need to know about it (duration, display
/// size, frame rate, waveform), a player for it and the playhead.
///
/// AVFoundation plays and reads the file itself when it can. For MKV, WebM, WMV and the like (`MediaSupport.needsFFmpegToRead`)
/// the session previews the small MP4/M4A proxy `ProxyMaker` makes; the numbers the job needs (the display size the crop
/// rectangle is measured in) still come from the original.
@MainActor
final class MediaSession: ObservableObject {
    enum Status: Equatable {
        case loading(String)
        case ready
        case failed(String)
    }

    let url: URL
    let isAudio: Bool

    @Published private(set) var status = Status.loading("Opening…")
    @Published private(set) var duration = 0.0
    /// Display size of the original's video, in pixels (what a crop rectangle is measured in); nil for audio.
    @Published private(set) var videoSize: CGSize?
    @Published private(set) var frameRate = 30.0
    /// The loudest sample in each slice of an audio file, 0...1.
    @Published private(set) var peaks: [Float] = []
    /// The frame at the playhead, when `generatesStills` is on (the crop editor draws it; headless snapshots show it).
    @Published private(set) var still: CGImage?
    @Published private(set) var playhead = 0.0
    @Published private(set) var isPlaying = false

    /// Playback stays inside this window (the trim editor's selection): it starts at the window's start and stops at its end.
    var playbackWindow: ClosedRange<Double>?
    /// Makes the session keep `still` current. Off for editors that show the live player.
    var generatesStills = false

    private(set) var player: AVPlayer?
    private let needsProxy: Bool
    private let ffmpeg: FFmpeg?
    /// Makes the preview proxy; replaced in tests.
    var proxyProvider: @Sendable (URL, FFmpeg, Bool) async throws -> URL = { url, ffmpeg, audioOnly in
        try await ProxyMaker.proxy(for: url, ffmpeg: ffmpeg, audioOnly: audioOnly)
    }

    private var generator: AVAssetImageGenerator?
    private var stillTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var statusObserver: AnyCancellable?
    private var isStopped = false

    init(item: DroppedItem, ffmpeg: FFmpeg?) {
        url = item.url
        isAudio = item.category == .audio
        needsProxy = MediaSupport.needsFFmpegToRead(item)
        self.ffmpeg = ffmpeg
    }

    /// The step the ◁| and |▷ buttons take: one frame for video, a tenth of a second for audio.
    var stepSize: Double { isAudio ? 0.1 : 1 / max(frameRate, 1) }

    /// The last time the playhead can reach: the last frame of a video, the end of an audio file.
    var lastTime: Double { isAudio ? duration : max(duration - stepSize, 0) }

    var isReady: Bool { status == .ready }

    // MARK: Loading

    func load() async {
        do {
            var playURL = url
            if needsProxy {
                guard let ffmpeg else {
                    throw OrbitError.unsupported("Previewing .\(url.pathExtension.lowercased()) files needs ffmpeg (brew install ffmpeg).")
                }
                status = .loading("Preparing a preview…")
                playURL = try await proxyProvider(url, ffmpeg, isAudio)
                if !isAudio, let stream = await MediaProbe.videoStream(of: url, ffmpeg: ffmpeg) {
                    videoSize = stream.displaySize
                    if let rate = stream.frameRate { frameRate = rate }
                }
            }
            let length = try await MediaInfo.duration(playURL)
            guard length > 0 else { throw OrbitError.unsupported("\(url.lastPathComponent) has no length to edit.") }
            if isAudio {
                peaks = try await Waveform.peaks(playURL, buckets: 480)
            } else {
                try await loadVideoFacts(playURL)
            }
            guard !isStopped else { return }
            duration = length
            makePlayer(for: playURL)
            status = .ready
            requestStill()
        } catch {
            Log.error("Media editor couldn't open \(url.lastPathComponent): \(error)")
            status = .failed(error.localizedDescription)
        }
    }

    private func loadVideoFacts(_ playURL: URL) async throws {
        let asset = AVURLAsset(url: playURL)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw OrbitError.unsupported("\(url.lastPathComponent) has no video to show.")
        }
        if videoSize == nil {
            guard let size = try await MediaInfo.videoSize(playURL), size.width > 0, size.height > 0 else {
                throw OrbitError.unsupported("Couldn't read the picture size of \(url.lastPathComponent).")
            }
            videoSize = size
            let rate = try await track.load(.nominalFrameRate)
            if rate > 0 { frameRate = Double(rate) }
        }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        self.generator = generator
    }

    private func makePlayer(for playURL: URL) {
        let player = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: playURL)))
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        statusObserver = player.publisher(for: \.timeControlStatus).receive(on: DispatchQueue.main).sink { [weak self] status in
            MainActor.assumeIsolated { self?.isPlaying = status != .paused }
        }
        self.player = player
    }

    /// Releases the player and stops anything still running. Safe to call twice.
    func stop() {
        isStopped = true
        stillTask?.cancel()
        generator?.cancelAllCGImageGeneration()
        player?.pause()
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        statusObserver = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
    }

    // MARK: Playhead

    func seek(to seconds: Double) {
        let t = min(max(seconds.isFinite ? seconds : 0, 0), lastTime)
        playhead = t
        player?.seek(to: CMTime(seconds: t, preferredTimescale: 6000), toleranceBefore: .zero, toleranceAfter: .zero)
        requestStill()
    }

    /// One step back (-1) or forward (+1). Video lands on a frame boundary.
    func step(_ direction: Int) {
        if isAudio {
            seek(to: ((playhead * 10).rounded() + Double(direction)) / 10)
        } else {
            seek(to: ((playhead * frameRate).rounded() + Double(direction)) / frameRate)
        }
    }

    func togglePlay() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            return
        }
        if let window = playbackWindow, playhead < window.lowerBound - 0.001 || playhead >= window.upperBound - 0.02 {
            seek(to: window.lowerBound)
        } else if playhead >= lastTime - 0.001 {
            seek(to: 0)
        }
        player.play()
    }

    private func tick(_ seconds: Double) {
        guard isPlaying, seconds.isFinite else { return }
        playhead = min(max(seconds, 0), duration)
        if let window = playbackWindow, seconds >= window.upperBound {
            player?.pause()
            seek(to: window.upperBound)
        }
    }

    private func requestStill() {
        guard generatesStills, let generator else { return }
        stillTask?.cancel()
        let time = CMTime(seconds: playhead, preferredTimescale: 6000)
        stillTask = Task { [weak self] in
            guard let result = try? await generator.image(at: time), !Task.isCancelled else { return }
            self?.still = result.image
        }
    }
}
