import Foundation
import CoreGraphics
import Testing
@testable import OrbitCore

@Suite struct MediaProbeTests {
    @Test func readsSizeAndFrameRate() {
        let listing = """
        Input #0, matroska,webm, from 'a.mkv':
          Duration: 00:00:05.43, start: 0.000000, bitrate: 6337 kb/s
          Stream #0:0: Video: h264 (High), yuv420p(tv, progressive), 1920x1080 [SAR 1:1 DAR 16:9], 29.97 fps, 30 tbr, 1k tbn
          Stream #0:1: Audio: aac (LC), 44100 Hz, mono, fltp
        """
        #expect(MediaProbe.parseVideoStream(listing) == .init(displaySize: CGSize(width: 1920, height: 1080), frameRate: 29.97))
    }

    @Test func ignoresTheHexCodecTag() {
        let listing = "  Stream #0:0[0x1](und): Video: h264 (High) (avc1 / 0x31637661), yuv420p(progressive), 1080x1920 [SAR 1:1 DAR 9:16], 6745 kb/s, 30 fps"
        #expect(MediaProbe.parseVideoStream(listing)?.displaySize == CGSize(width: 1080, height: 1920))
    }

    @Test func aQuarterTurnSwapsTheDisplaySize() {
        let listing = """
          Stream #0:0: Video: h264, yuv420p, 1920x1080, 30 fps, 30 tbr
          Side data:
            displaymatrix: rotation of -90.00 degrees
          Stream #0:1: Audio: aac, 44100 Hz
        """
        #expect(MediaProbe.parseVideoStream(listing)?.displaySize == CGSize(width: 1080, height: 1920))
    }

    @Test func aRotationUnderAnotherStreamDoesNotApply() {
        let listing = """
          Stream #0:0: Video: h264, yuv420p, 640x360, 24 fps
          Stream #0:1: Audio: aac, 44100 Hz
            displaymatrix: rotation of 90.00 degrees
        """
        #expect(MediaProbe.parseVideoStream(listing)?.displaySize == CGSize(width: 640, height: 360))
    }

    @Test func noVideoStreamIsNil() {
        #expect(MediaProbe.parseVideoStream("  Stream #0:0: Audio: mp3, 44100 Hz, stereo") == nil)
        #expect(MediaProbe.parseVideoStream("") == nil)
    }

    @Test func aProbeThatCannotRunThrowsInsteadOfLookingLikeAFileWithoutVideo() async {
        let missing = FFmpeg(executable: URL(fileURLWithPath: "/nonexistent/ffmpeg-for-test"))
        await #expect(throws: (any Error).self) {
            _ = try await MediaProbe.videoStream(of: URL(fileURLWithPath: "/tmp/a.mkv"), ffmpeg: missing)
        }
    }

    @Test func aCancelledProbeThrowsCancelled() async {
        let task = Task { () -> Bool in
            // /bin/sleep stands in for ffmpeg: it ignores `-hide_banner`, so it fails at once; cancel before it runs.
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await MediaProbe.videoStream(of: URL(fileURLWithPath: "/tmp/a.mkv"), ffmpeg: FFmpeg(executable: URL(fileURLWithPath: "/bin/sleep")))
                return false
            } catch OrbitError.cancelled {
                return true
            } catch {
                return false
            }
        }
        #expect(await task.value)
    }
}
