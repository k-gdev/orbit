import Foundation

public enum AppleScriptRunner {
    /// The `--` stops osascript from reading a leading-dash argument as one of its own options.
    /// Paths and other user data go in `arguments` and reach the script through `on run argv`.
    public static func run(_ script: String, arguments: [String]) async throws -> String {
        let r = try await ProcessRunner.run(URL(filePath: "/usr/bin/osascript"), ["-e", script, "--"] + arguments)
        return String(r.stdout.reversed().drop(while: \.isWhitespace).reversed())
    }
}
