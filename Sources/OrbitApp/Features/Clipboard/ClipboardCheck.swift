import AppKit
import OrbitCore

/// Hidden command-line check: `Orbit --check-clipboard`. Exercises `PasteboardReader` and
/// `PasteboardWriter` on private NAMED pasteboards (released afterwards), so the user's real clipboard
/// is never read or written, and posts no key events. Prints one PASS/FAIL line per case and exits 0
/// when every case passed.
enum ClipboardCheck {
    static let flag = "--check-clipboard"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard arguments.contains(flag) else { return }
        NSApplication.shared.setActivationPolicy(.prohibited)
        let ok = run()
        exit(ok ? 0 : 1)
    }

    @MainActor
    private static func run() -> Bool {
        var failures = 0
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(passed ? "PASS" : "FAIL")  \(name)\(passed ? "" : "  \(detail())")")
            if !passed { failures += 1 }
        }

        let policy = PasteboardPolicy(ignoredBundleIDs: ["com.example.ignored"], maxItemBytes: 1_000_000)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let frontmost = ClipboardSourceApp(bundleID: "com.example.front", name: "Front")
        func makeBoard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("com.kevo.orbit.check.\(UUID().uuidString)"))
        }
        func capture(from board: NSPasteboard, policy: PasteboardPolicy = policy) -> PasteboardRead {
            PasteboardReader.read(board, policy: policy, frontmost: frontmost, now: now)
        }
        func skipped(_ read: PasteboardRead) -> Bool { if case .skipped = read { return true } else { return false } }
        func isNothing(_ read: PasteboardRead) -> Bool { if case .nothing = read { return true } else { return false } }

        // Plain text, with the frontmost app as the source.
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setString("Hello  clipboard\nline two", forType: .string)
            if case .capture(let c) = capture(from: board) {
                check("plain text is captured", c.kind == .text && c.preview == "Hello clipboard line two"
                      && c.sourceBundleID == "com.example.front" && c.sourceName == "Front", "\(c)")
                // And back out again through the writer.
                let item = c.makeItem(payloadFile: "x")
                let target = makeBoard(); defer { target.releaseGlobally() }
                let outcome = PasteboardWriter.write(item, payload: c.payload, to: target)
                check("text is written back", target.string(forType: .string) == "Hello  clipboard\nline two"
                      && outcome == .written(changeCount: target.changeCount))
            } else { check("plain text is captured", false) }
        }

        // Password-manager markers and an ignored source app.
        for marker in ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "com.agilebits.onepassword"] {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents()
            board.declareTypes([.string, NSPasteboard.PasteboardType(marker)], owner: nil)
            board.setString("hunter2", forType: .string)
            board.setString("", forType: NSPasteboard.PasteboardType(marker))
            check("\(marker) is skipped", skipped(capture(from: board)))
        }
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setString("from an ignored app", forType: .string)
            board.setString("com.example.ignored", forType: PasteboardReader.sourceType)
            check("an ignored source app is skipped", skipped(capture(from: board)))
        }
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setString("named source", forType: .string)
            board.setString("com.apple.finder", forType: PasteboardReader.sourceType)
            if case .capture(let c) = capture(from: board) {
                check("the pasteboard's own source marker names the app", c.sourceBundleID == "com.apple.finder", "\(c.sourceBundleID ?? "nil")")
            } else { check("the pasteboard's own source marker names the app", false) }
        }

        // Rich text.
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            let attributed = NSAttributedString(string: "Bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
            let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) ?? Data()
            board.clearContents(); board.setData(rtf, forType: .rtf); board.setString("Bold words", forType: .string)
            if case .capture(let c) = capture(from: board) {
                check("rich text is captured as RTF", c.kind == .richText && c.preview == "Bold words" && c.payload == rtf)
                let target = makeBoard(); defer { target.releaseGlobally() }
                PasteboardWriter.write(c.makeItem(payloadFile: "x"), payload: c.payload, to: target)
                check("rich text is written back with its plain text", target.data(forType: .rtf) == rtf && target.string(forType: .string) == "Bold words")
            } else { check("rich text is captured as RTF", false) }
        }

        // Images: PNG as is, TIFF converted to PNG.
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = bitmap.representation(using: .png, properties: [:]) ?? Data()
        let tiff = bitmap.representation(using: .tiff, properties: [:]) ?? Data()
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setData(png, forType: .png)
            if case .capture(let c) = capture(from: board) {
                check("a PNG image is captured", c.kind == .image && c.preview == "Image 64 × 32" && c.payload == png, c.preview)
                let target = makeBoard(); defer { target.releaseGlobally() }
                PasteboardWriter.write(c.makeItem(payloadFile: "x"), payload: c.payload, to: target)
                check("an image is written back as PNG", target.data(forType: .png) == png)
            } else { check("a PNG image is captured", false) }
        }
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setData(tiff, forType: .tiff)
            if case .capture(let c) = capture(from: board) {
                check("a TIFF image is stored as PNG", c.kind == .image && c.preview == "Image 64 × 32"
                      && c.payload.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), c.preview)
            } else { check("a TIFF image is stored as PNG", false) }
        }

        // Files (the real files stay where they are; only their paths are stored).
        do {
            let folder = FileManager.default.temporaryDirectory.appending(path: "orbit-clipboard-check-\(UUID().uuidString)", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let file = folder.appending(path: "report.txt")
            try? Data("x".utf8).write(to: file)
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.writeObjects([file as NSURL])
            if case .capture(let c) = capture(from: board) {
                let paths = ClipboardPayload.filePaths(from: c.payload)
                check("copied files are captured by path", c.kind == .files && c.preview == "report.txt"
                      && paths.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == [file.resolvingSymlinksInPath().path], "\(paths)")
                let target = makeBoard(); defer { target.releaseGlobally() }
                let outcome = PasteboardWriter.write(c.makeItem(payloadFile: "x"), payload: c.payload, to: target)
                let back = (target.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.map(\.lastPathComponent)
                check("files are written back as file URLs", back == ["report.txt"] && outcome == .written(changeCount: target.changeCount), "\(String(describing: back))")
                // A file that has since been deleted is not offered.
                try? FileManager.default.removeItem(at: file)
                let gone = makeBoard(); defer { gone.releaseGlobally() }
                check("files that are gone are not written", PasteboardWriter.write(c.makeItem(payloadFile: "x"), payload: c.payload, to: gone)
                      == .unavailable("Those files are no longer there") && (gone.types ?? []).isEmpty)
            } else { check("copied files are captured by path", false) }
        }

        // Size limit, whitespace-only text and an empty pasteboard.
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setString(String(repeating: "x", count: 1_500_000), forType: .string)
            check("a copy over the per-copy limit is skipped", skipped(capture(from: board)))
            board.clearContents(); board.setString("  \n\t ", forType: .string)
            check("whitespace-only text is skipped", skipped(capture(from: board)))
            board.clearContents()
            check("an empty pasteboard gives nothing", isNothing(capture(from: board)))
        }

        print(failures == 0 ? "all clipboard checks passed" : "\(failures) clipboard check(s) failed")
        return failures == 0
    }
}
