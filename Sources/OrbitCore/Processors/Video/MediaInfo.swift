import AVFoundation
import Foundation

/// Facts about a media file read through AVFoundation. Shared by the video, audio and editor tasks.
public enum MediaInfo {
    public static func duration(_ url: URL) async throws -> Double {
        let seconds = try await AVURLAsset(url: url).load(.duration).seconds
        guard seconds.isFinite else { throw OrbitError.unsupported("Couldn't read the duration of \(url.lastPathComponent).") }
        return seconds
    }

    /// The display size of the first video track, after its `preferredTransform`; nil when there is no video.
    public static func videoSize(_ url: URL) async throws -> CGSize? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return nil }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let rect = CGRect(origin: .zero, size: size).applying(transform)
        return CGSize(width: abs(rect.width).rounded(), height: abs(rect.height).rounded())
    }

    public static func hasAudio(_ url: URL) async throws -> Bool {
        try await !AVURLAsset(url: url).loadTracks(withMediaType: .audio).isEmpty
    }

    public static func hasVideo(_ url: URL) async throws -> Bool {
        try await !AVURLAsset(url: url).loadTracks(withMediaType: .video).isEmpty
    }

    /// Channels in the first audio track; 0 when there is no audio.
    public static func channelCount(_ url: URL) async throws -> Int {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return 0 }
        let descriptions = try await track.load(.formatDescriptions)
        for description in descriptions {
            if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                return Int(asbd.mChannelsPerFrame)
            }
        }
        return 0
    }
}
