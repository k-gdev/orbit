import AppKit
import OrbitCore

/// Puts a history entry back on a pasteboard, in the formats it was copied in.
enum PasteboardWriter {
    enum Outcome: Equatable {
        /// Written; `changeCount` is the pasteboard's count right after, so the watcher can ignore it.
        case written(changeCount: Int)
        /// Nothing was written (the reason is short enough for a toast).
        case unavailable(String)
    }

    @discardableResult
    static func write(_ item: ClipboardItem, payload: Data, to pasteboard: NSPasteboard) -> Outcome {
        switch item.kind {
        case .text:
            guard let text = String(data: payload, encoding: .utf8) else { return .unavailable("This copy can't be read any more") }
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
        case .richText:
            let plain = NSAttributedString(rtf: payload, documentAttributes: nil)?.string ?? item.preview
            pasteboard.clearContents()
            pasteboard.setData(payload, forType: .rtf)
            pasteboard.setString(plain, forType: .string)
        case .image:
            pasteboard.clearContents()
            pasteboard.setData(payload, forType: .png)
        case .files:
            // Only files that are still there; pasting a path that no longer exists helps nobody.
            let urls = ClipboardPayload.filePaths(from: payload)
                .filter { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0) }
            guard !urls.isEmpty else { return .unavailable("Those files are no longer there") }
            pasteboard.clearContents()
            pasteboard.writeObjects(urls as [NSURL])
        }
        return .written(changeCount: pasteboard.changeCount)
    }
}
