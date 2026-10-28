import Foundation

/// Do Not Disturb / Focus has no public API, so Controls runs a Shortcut the user picks (one with the
/// "Set Focus" action) through the `shortcuts` command-line tool.
public enum FocusShortcut {
    public static let executable = URL(fileURLWithPath: "/usr/bin/shortcuts")

    /// `shortcuts list` output → the Shortcut names, trimmed, de-duplicated and sorted.
    public static func parseList(_ output: String) -> [String] {
        let names = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Array(Set(names)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Arguments that run one Shortcut by name (no shell involved).
    public static func runArguments(_ name: String) -> [String] { ["run", name] }

    /// How long a Shortcut run may take before Orbit gives up on it (and terminates `shortcuts`), so the
    /// Do Not Disturb button can't sit on "Working…" forever.
    public static let timeout: TimeInterval = 15

    public struct TimedOut: Error, LocalizedError {
        public var errorDescription: String? { "It took longer than \(Int(FocusShortcut.timeout)) seconds." }
    }

    /// Runs `operation`, cancelling it and throwing `TimedOut` when it takes longer than `seconds`.
    /// Cancellation reaches `ProcessRunner`, which terminates the child process.
    public static func withTimeout<T: Sendable>(_ seconds: TimeInterval,
                                                _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                throw TimedOut()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw TimedOut() }
            return first
        }
    }
}
