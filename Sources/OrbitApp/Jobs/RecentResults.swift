import Foundation
import OrbitCore

/// The last 10 job results, newest first, for the menu's "Recent results" submenu.
@MainActor
final class RecentResults {
    static let limit = 10

    struct Entry: Identifiable {
        let id = UUID()
        let result: JobResult

        /// The menu title: the first output's file name, or the summary when nothing was written.
        var title: String {
            guard let first = result.outputs.first else { return result.summary }
            let extra = result.outputs.count - 1
            return extra > 0 ? "\(first.lastPathComponent) + \(extra) more" : first.lastPathComponent
        }
    }

    private(set) var entries: [Entry] = []

    func add(_ result: JobResult) {
        entries.insert(Entry(result: result), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
    }

    /// Forgets results whose outputs were undone.
    func remove(outputs: [URL]) {
        entries.removeAll { $0.result.outputs == outputs }
    }
}
