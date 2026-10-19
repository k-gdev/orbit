import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs external programs. Arguments are always an array; no shell is involved.
public enum ProcessRunner {
    /// Runs `exe` and throws `OrbitError.processFailed` on a non-zero exit.
    /// If `stdoutFile` is given, stdout is written straight to it (it must not exist, or be empty).
    public static func run(
        _ exe: URL,
        _ args: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let result = try await runCapturing(exe, args, currentDirectory: currentDirectory,
                                            stdoutFile: stdoutFile, onStdoutLine: onStdoutLine)
        guard result.exitCode == 0 else {
            let tool = exe.lastPathComponent
            let tail = String(result.stderr.suffix(2000))
            Log.error("\(tool) exited with \(result.exitCode): \(tail)")
            throw OrbitError.processFailed(tool: tool, code: result.exitCode, stderr: tail)
        }
        return result
    }

    /// Like `run`, but a non-zero exit is returned rather than thrown (cancellation and launch errors still throw).
    static func runCapturing(
        _ exe: URL,
        _ args: [String],
        currentDirectory: URL? = nil,
        stdoutFile: URL? = nil,
        onStdoutLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = exe
        process.arguments = args
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        var fileHandle: FileHandle?
        if let stdoutFile {
            fileHandle = try openForWriting(stdoutFile)
        }
        defer { try? fileHandle?.close() }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = fileHandle ?? outPipe
        process.standardError = errPipe

        let state = RunState()
        let outReader = StreamReader(onLine: onStdoutLine)
        let errReader = StreamReader(onLine: nil)
        // Each pipe has exactly one reader that reads until EOF, so output stays in order and
        // nothing is lost at exit. Resume only when both pipes hit EOF and the process has exited.
        let group = DispatchGroup()
        func drain(_ pipe: Pipe, into reader: StreamReader) {
            group.enter()
            DispatchQueue.global().async {
                let h = pipe.fileHandleForReading
                while let d = try? h.read(upToCount: 65536), !d.isEmpty { reader.append(d) }
                try? h.close()
                group.leave()
            }
        }

        let exitCode: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
                group.enter()
                let status = StatusBox()
                process.terminationHandler = { p in
                    status.value = p.terminationStatus
                    group.leave()
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    try? outPipe.fileHandleForWriting.close()
                    try? errPipe.fileHandleForWriting.close()
                    cont.resume(throwing: error)
                    return
                }
                // The parent's copies of the write ends must close so EOF can arrive.
                if fileHandle == nil { try? outPipe.fileHandleForWriting.close() }
                try? errPipe.fileHandleForWriting.close()
                if fileHandle == nil { drain(outPipe, into: outReader) }
                drain(errPipe, into: errReader)
                group.notify(queue: .global()) { cont.resume(returning: status.value) }
                state.started(process)
            }
        } onCancel: {
            state.cancel()
        }

        if state.wasCancelled || Task.isCancelled { throw OrbitError.cancelled }
        outReader.finish()
        return ProcessResult(exitCode: exitCode, stdout: outReader.text, stderr: errReader.text)
    }

    private static func openForWriting(_ url: URL) throws -> FileHandle {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            guard size == 0 else {
                throw OrbitError.unsupported("Refusing to overwrite existing file \(url.lastPathComponent).")
            }
        } else {
            guard fm.createFile(atPath: url.path, contents: nil) else {
                throw OrbitError.unsupported("Couldn't create \(url.lastPathComponent).")
            }
        }
        return try FileHandle(forWritingTo: url)
    }
}

/// Tracks the running process so cancellation can SIGTERM it, then SIGKILL after 2 s.
private final class RunState: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func started(_ p: Process) {
        lock.lock()
        process = p
        let c = cancelled
        lock.unlock()
        if c { terminate(p) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p { terminate(p) }
    }

    private func terminate(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let pid = p.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
            if p.isRunning { kill(pid, SIGKILL) }
        }
    }
}

/// Accumulates a stream's bytes and optionally reports complete lines.
private final class StreamReader: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: all, as: UTF8.self) }

    func append(_ d: Data) {
        lock.lock()
        all.append(d)
        var lines: [String] = []
        if onLine != nil {
            pending.append(d)
            while let nl = pending.firstIndex(of: 0x0A) {
                lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...nl)
            }
        }
        lock.unlock()
        if let onLine { lines.forEach(onLine) }
    }

    /// Flushes a final line that had no trailing newline.
    func finish() {
        lock.lock()
        let rest = pending
        pending = Data()
        lock.unlock()
        if let onLine, !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
    }
}

private final class StatusBox: @unchecked Sendable { var value: Int32 = 0 }
