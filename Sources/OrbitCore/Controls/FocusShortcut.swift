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
}
