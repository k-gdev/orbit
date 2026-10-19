import Foundation

/// The bitrates and height a compressed video is encoded with.
public struct VideoBitratePlan: Equatable, Sendable {
    public var videoKbps: Int
    public var audioKbps: Int
    /// The height to scale down to; nil leaves the size alone.
    public var maxHeight: Int?

    public init(videoKbps: Int, audioKbps: Int, maxHeight: Int?) {
        self.videoKbps = videoKbps
        self.audioKbps = audioKbps
        self.maxHeight = maxHeight
    }
}

public enum VideoBitrate {
    /// Smallest video bitrate worth encoding.
    static let minimumVideoKbps = 100

    /// Splits the bits a target allows (with 5% headroom for the container) between audio and video, and
    /// picks a height the video bitrate can carry. Nil when even the smallest useful video won't fit.
    public static func plan(durationSeconds: Double, targetBytes: Int64, sourceHeight: Int, hasAudio: Bool) -> VideoBitratePlan? {
        guard durationSeconds > 0, durationSeconds.isFinite, targetBytes > 0 else { return nil }
        let total = Double(targetBytes) * 8 * 0.95 / durationSeconds / 1000
        let audio = hasAudio ? (total >= 1000 ? 128 : 64) : 0
        let video = Int(total) - audio
        guard video >= minimumVideoKbps else { return nil }

        let height: Int? = if video < 600 { 480 } else if video < 1500 { 720 } else if video < 4000 { 1080 } else { nil }
        let maxHeight = height.flatMap { $0 < sourceHeight ? $0 : nil }
        return VideoBitratePlan(videoKbps: video, audioKbps: audio, maxHeight: maxHeight)
    }
}
