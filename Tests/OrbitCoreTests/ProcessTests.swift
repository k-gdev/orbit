import Testing
import Foundation
@testable import OrbitCore

private let weird = "-rf 'q\" ü.mov"

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appending(path: "orbit-process-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    return dir
}

@Suite struct ProcessTests {
    @Test func argumentsPassVerbatim() async throws {
        let r = try await ProcessRunner.run(URL(filePath: "/usr/bin/printf"), ["%s", weird])
        #expect(r.stdout == weird)
    }

    @Test func nonZeroExitThrows() async {
        await #expect(throws: OrbitError.processFailed(tool: "sh", code: 3, stderr: "")) {
            try await ProcessRunner.run(URL(filePath: "/bin/sh"), ["-c", "exit 3"])
        }
    }

    @Test func cancellationTerminates() async {
        let t = Task { try await ProcessRunner.run(URL(filePath: "/bin/sleep"), ["10"]) }
        try? await Task.sleep(for: .milliseconds(200))
        t.cancel()
        let start = Date()
        await #expect(throws: OrbitError.cancelled) { try await t.value }
        #expect(Date().timeIntervalSince(start) < 3)
    }

    @Test func ffmpegParsers() {
        #expect(FFmpeg.parseDuration("  Duration: 01:02:03.45, start") == 3723.45)
        #expect(FFmpeg.progressFraction(line: "out_time_us=2500000", duration: 5) == 0.5)
        #expect(FFmpeg.progressFraction(line: "progress=end", duration: 5) == 1)
        #expect(FFmpeg.pathArg(URL(filePath: "/tmp/\(weird)")) == "file:/tmp/\(weird)")
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg")))
    func ffmpegRunsAndNeverOverwrites() async throws {
        let tmp = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let f = FFmpeg(executable: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        let out = tmp.appending(path: "-rf 'q\" ü.m4a")
        let src = ["-f", "lavfi", "-i", "sine=frequency=440:duration=1", "-c:a", "aac"]
        try await f.run(inputs: [], args: src, output: out, duration: 1, progress: { _ in })
        #expect(abs(try await f.duration(of: out) - 1.0) < 0.05)
        await #expect(throws: (any Error).self) {
            try await f.run(inputs: [], args: src, output: out, duration: 1, progress: { _ in })
        }
    }

    @Test func appleScriptArgv() async throws {
        let s = "on run argv\nreturn (item 1 of argv) & \"|\" & (item 2 of argv)\nend run"
        #expect(try await AppleScriptRunner.run(s, arguments: [weird, "-x"]) == "\(weird)|-x")
    }
}
