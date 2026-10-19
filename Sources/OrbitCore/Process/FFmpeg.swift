import Foundation

public struct FFmpeg: Sendable {
    public let executable: URL
    /// Whether h264_videotoolbox accepts `-q:v` here: only when ffmpeg runs as arm64 (FFmpeg's
    /// `vtenc_qscale_enabled` is `TARGET_CPU_ARM64`). An Intel Mac, or an x86_64-only ffmpeg under
    /// Rosetta, needs a bitrate instead.
    public let videoToolboxQScale: Bool

    public init(executable: URL) {
        self.init(executable: executable, videoToolboxQScale: Self.runsAsARM64(executable))
    }

    public init(executable: URL, videoToolboxQScale: Bool) {
        self.executable = executable
        self.videoToolboxQScale = videoToolboxQScale
    }

    /// True when Orbit runs as arm64 and the executable has an arm64 slice, so the child runs as arm64.
    static func runsAsARM64(_ executable: URL) -> Bool {
        #if arch(arm64)
        return hasARM64Slice(executable)
        #else
        return false
        #endif
    }

    /// Reads the Mach-O header (thin or universal) for an arm64 slice.
    static func hasARM64Slice(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable.resolvingSymlinksInPath()) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4096), data.count >= 8 else { return false }
        let b = [UInt8](data)
        func be32(_ i: Int) -> UInt32 { i + 4 <= b.count ? UInt32(b[i]) << 24 | UInt32(b[i + 1]) << 16 | UInt32(b[i + 2]) << 8 | UInt32(b[i + 3]) : 0 }
        func le32(_ i: Int) -> UInt32 { i + 4 <= b.count ? UInt32(b[i + 3]) << 24 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i]) : 0 }
        let arm64: UInt32 = 0x0100_000C
        switch be32(0) {
        case 0xCAFE_BABE, 0xCAFE_BABF: // universal: big-endian fat_arch (20 bytes) or fat_arch_64 (32 bytes)
            let stride = be32(0) == 0xCAFE_BABE ? 20 : 32
            let count = Int(min(be32(4), 64))
            return (0..<count).contains { be32(8 + $0 * stride) == arm64 }
        default:
            return le32(0) == 0xFEED_FACF && le32(4) == arm64 // thin 64-bit Mach-O, little-endian
        }
    }

    /// ffmpeg treats a leading `-` as an option; the `file:` prefix prevents that.
    public static func pathArg(_ url: URL) -> String { "file:" + url.path }

    public static let baseArgs = ["-hide_banner", "-nostdin", "-n", "-loglevel", "error", "-progress", "pipe:1"]

    public func run(
        inputs: [URL],
        args: [String],
        output: URL,
        duration: Double?,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let argv = Self.baseArgs + inputs.flatMap { ["-i", Self.pathArg($0)] } + args + [Self.pathArg(output)]
        // `-n` makes ffmpeg refuse to overwrite, but recent versions still exit 0 when they do,
        // so an existing output is reported as a failure here rather than trusting the exit code.
        let tool = executable.lastPathComponent
        if FileManager.default.fileExists(atPath: output.path) {
            Log.error("\(tool) not run: output already exists: \(output.lastPathComponent)")
            throw OrbitError.processFailed(tool: tool, code: 1, stderr: "Output file already exists.")
        }
        let result = try await ProcessRunner.run(executable, argv, onStdoutLine: { line in
            if let duration, let f = Self.progressFraction(line: line, duration: duration) { progress(f) }
        })
        if result.stderr.contains("already exists. Exiting.") {
            Log.error("\(tool) refused to overwrite: \(result.stderr)")
            throw OrbitError.processFailed(tool: tool, code: 1, stderr: String(result.stderr.suffix(2000)))
        }
        progress(1)
    }

    /// True for `run`'s refusal to write over an existing output. That file isn't Orbit's, so a retry
    /// must never remove it.
    public static func isExistingOutputRefusal(_ error: any Error) -> Bool {
        guard case .processFailed(_, _, let stderr)? = error as? OrbitError else { return false }
        return stderr == "Output file already exists." || stderr.contains("already exists. Exiting.")
    }

    public static func progressFraction(line: String, duration: Double) -> Double? {
        let l = line.trimmingCharacters(in: .whitespaces)
        if l == "progress=end" { return 1 }
        for key in ["out_time_us=", "out_time_ms="] where l.hasPrefix(key) {
            guard duration > 0, let micros = Double(l.dropFirst(key.count)) else { return nil }
            return min(1, max(0, micros / 1_000_000 / duration))
        }
        return nil
    }

    /// Runs `ffmpeg -i file` with no output, which exits non-zero but prints the stream info to stderr.
    public func duration(of url: URL) async throws -> Double {
        let r = try await ProcessRunner.runCapturing(executable, ["-hide_banner", "-i", Self.pathArg(url)])
        guard let d = Self.parseDuration(r.stderr) else {
            throw OrbitError.unsupported("Couldn't read the duration of \(url.lastPathComponent).")
        }
        return d
    }

    public static func parseDuration(_ stderr: String) -> Double? {
        let re = try! NSRegularExpression(pattern: #"Duration:\s*(\d+):(\d+):(\d+(?:\.\d+)?)"#)
        let ns = stderr as NSString
        guard let m = re.firstMatch(in: stderr, range: NSRange(location: 0, length: ns.length)),
              let h = Double(ns.substring(with: m.range(at: 1))),
              let min = Double(ns.substring(with: m.range(at: 2))),
              let s = Double(ns.substring(with: m.range(at: 3))) else { return nil }
        return h * 3600 + min * 60 + s
    }

    public static func hasAudioStream(_ stderr: String) -> Bool { hasStream(stderr, kind: "Audio:") }
    public static func hasVideoStream(_ stderr: String) -> Bool { hasStream(stderr, kind: "Video:") }

    private static func hasStream(_ stderr: String, kind: String) -> Bool {
        stderr.split(whereSeparator: \.isNewline).contains { $0.contains("Stream #") && $0.contains(kind) }
    }
}
