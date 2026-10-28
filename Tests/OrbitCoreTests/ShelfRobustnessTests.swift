import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

/// Shelf fix round 1: items on a drive that is offline are kept (not pruned), a damaged shelf file is
/// preserved, and the shake poller that replaces the dependence on global drag events.
@Suite struct ShelfRobustnessTests {
    // MARK: Availability (I1)

    /// A pretend file system: these paths exist, these answer with an error, everything else is absent.
    private static func probe(present: Set<String>, unavailable: Set<String> = []) -> (URL) -> ShelfProbeResult {
        { url in
            let path = url.standardizedFileURL.path
            if unavailable.contains(path) { return .unavailable }
            return present.contains(path) ? .exists : .absent
        }
    }

    private static func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func volumeRootComesFromThePath() {
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/NAS/Projects/a.psd")).path == "/Volumes/NAS")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/Backup Drive/x")).path == "/Volumes/Backup Drive")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes/NAS")).path == "/Volumes/NAS")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Users/kevo/Desktop/a.txt")).path == "/")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/Volumes")).path == "/")
        #expect(ShelfAvailability.volumeRoot(of: Self.url("/System/Volumes/Data/Users/kevo/a")).path == "/")
    }

    @Test func aFileThatIsThereIsAvailable() {
        let probe = Self.probe(present: ["/Volumes/NAS/a.txt"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: probe) == .available)
    }

    /// The drive is up and the file is not on it: it really is gone, so the shelf may drop it.
    @Test func goneFileOnAMountedVolumeIsMissing() {
        let probe = Self.probe(present: ["/Volumes/NAS", "/Volumes/NAS/other.txt"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: probe) == .missing)
        // Same for a file on the startup disk.
        #expect(ShelfAvailability.status(of: Self.url("/Users/kevo/Desktop/a.txt"), probe: Self.probe(present: [])) == .missing)
    }

    /// The drive is not mounted (unplugged USB, sleeping or disconnected NAS): the file is not gone, it is
    /// out of reach, and the shelf must keep it.
    @Test func fileOnAnUnmountedVolumeIsUnreachableNotMissing() {
        let probe = Self.probe(present: ["/Volumes/Other"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/Projects/a.psd"), probe: probe) == .unreachable)
    }

    /// An error that is not "no such file" (permission denied, timeout, stale network handle) proves nothing
    /// about the file, so it is never treated as gone.
    @Test func anErrorIsNeverTreatedAsGone() {
        let denied = Self.probe(present: [], unavailable: ["/Users/kevo/Documents/a.pdf"])
        #expect(ShelfAvailability.status(of: Self.url("/Users/kevo/Documents/a.pdf"), probe: denied) == .unreachable)
        // The file is absent but the volume cannot be checked: still unreachable.
        let stuck = Self.probe(present: [], unavailable: ["/Volumes/NAS"])
        #expect(ShelfAvailability.status(of: Self.url("/Volumes/NAS/a.txt"), probe: stuck) == .unreachable)
    }

    @Test func errnoMapsToAProbeResult() {
        #expect(ShelfAvailability.probeResult(errnoValue: nil) == .exists)
        #expect(ShelfAvailability.probeResult(errnoValue: ENOENT) == .absent)
        #expect(ShelfAvailability.probeResult(errnoValue: ENOTDIR) == .absent)
        for code in [EACCES, EPERM, EIO, ETIMEDOUT, ESTALE, ENXIO, EINTR, ENOTCONN] {
            #expect(ShelfAvailability.probeResult(errnoValue: code) == .unavailable, "errno \(code)")
        }
    }

    @Test func realProbeSeesTheFilesystem() throws {
        let dir = Fixtures.tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = Fixtures.file("here.txt", "x", in: dir)
        #expect(ShelfAvailability.probe(file) == .exists)
        #expect(ShelfAvailability.probe(dir) == .exists)
        #expect(ShelfAvailability.probe(dir.appending(path: "nope.txt")) == .absent)
        // A path that goes through a file is "not a directory", still plainly absent.
        #expect(ShelfAvailability.probe(file.appending(path: "inside.txt")) == .absent)
        // A temp folder is on the startup disk, so a deleted file there is genuinely missing.
        try FileManager.default.removeItem(at: file)
        #expect(ShelfAvailability.status(of: file, probe: ShelfAvailability.probe) == .missing)
    }
}
