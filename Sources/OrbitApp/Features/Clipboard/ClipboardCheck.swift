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
        let tally = Tally()
        func check(_ name: String, _ passed: Bool, _ detail: @autoclosure () -> String = "") {
            print("\(passed ? "PASS" : "FAIL")  \(name)\(passed ? "" : "  \(detail())")")
            if !passed { tally.failures += 1 }
        }

        let policy = PasteboardPolicy(ignoredBundleIDs: ["com.example.ignored"],
                                      limits: ClipboardLimits(maxItems: 100, maxAge: 86_400, maxTotalBytes: 100_000_000, maxItemBytes: 1_000_000))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let frontmost = ClipboardSourceApp(bundleID: "com.example.front", name: "Front")
        func makeBoard() -> NSPasteboard {
            NSPasteboard(name: NSPasteboard.Name("com.kevo.orbit.check.\(UUID().uuidString)"))
        }
        /// What the app ends up with: the reader's raw bytes taken through `makeCapture`, the same two
        /// steps the app runs (the second one on a background queue).
        enum Checked { case nothing, skipped(String), capture(ClipboardCapture) }
        func capture(from board: NSPasteboard, policy: PasteboardPolicy = policy, afterTypes: (() -> Void)? = nil) -> Checked {
            switch PasteboardReader.read(board, policy: policy, frontmost: frontmost, now: now, afterTypes: afterTypes) {
            case .nothing: return .nothing
            case .skipped(let reason): return .skipped(reason)
            case .copy(let raw):
                switch raw.makeCapture(maxItemBytes: policy.limits.maxItemBytes) {
                case .capture(let c): return .capture(c)
                case .skipped(let reason): return .skipped(reason)
                }
            }
        }
        func skipped(_ read: Checked) -> Bool { if case .skipped = read { return true } else { return false } }
        func isNothing(_ read: Checked) -> Bool { if case .nothing = read { return true } else { return false } }

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

        // An image is judged by the PNG that is stored, not by the (uncompressed) TIFF it arrived as.
        do {
            let side = 500
            let flat = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            if let pixels = flat.bitmapData { for i in 0..<(flat.bytesPerRow * side) { pixels[i] = 180 } }
            let flatTIFF = flat.representation(using: .tiff, properties: [:]) ?? Data()
            var tight = policy
            tight.limits.maxItemBytes = 200_000
            check("(setup) the TIFF is over the per-copy limit", flatTIFF.count > tight.limits.maxItemBytes, "\(flatTIFF.count) bytes")
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setData(flatTIFF, forType: .tiff)
            if case .capture(let c) = capture(from: board, policy: tight) {
                check("a TIFF whose PNG fits is captured although the TIFF is over the limit",
                      c.kind == .image && c.payload.count <= tight.limits.maxItemBytes && c.payload.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]),
                      "\(c.payload.count) bytes")
            } else { check("a TIFF whose PNG fits is captured although the TIFF is over the limit", false) }
            var tiny = policy
            tiny.limits.maxItemBytes = flatTIFF.count / 20   // the TIFF is beyond ten times this
            check("a TIFF far beyond the limit is not even converted", skipped(capture(from: board, policy: tiny)))
        }

        // A change between the marker check and the content read is caught (the markers may belong to
        // other content), so neither the old nor the new content is recorded from that read.
        do {
            let board = makeBoard(); defer { board.releaseGlobally() }
            board.clearContents(); board.setString("an ordinary copy", forType: .string)
            let result = capture(from: board, afterTypes: {
                board.clearContents()
                board.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
                board.setString("a password that arrived just after", forType: .string)
            })
            check("a pasteboard that changes mid-read is discarded", skipped(result), "\(result)")
            // Read again (the next poll does): now the markers are seen and the secret is refused too.
            check("... and the secret is refused on the re-read", skipped(capture(from: board)))
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

        // Turning the feature off while copies are still being processed: nothing is written or added after
        // `cancelIngest()`, however many copies were queued, and copies after a restart are handled again.
        // The store is a throwaway folder (removed at exit); no pasteboard is involved.
        do {
            let folder = SnapshotFixtures.directory()
            let model = ClipboardModel(settings: ClipboardFixtures.settings(), store: ClipboardStore(directory: folder))
            func copy(_ text: String) -> RawPasteboardCopy {
                RawPasteboardCopy(content: .text(Data(text.utf8)), sourceBundleID: "com.example.front", sourceName: "Front", date: now)
            }
            func blobs() -> [String] {
                ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != ClipboardStore.indexName }
            }
            func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.5)) }
            for text in ["first queued copy", "second queued copy", "third queued copy"] { model.ingest(copy(text)) }
            model.cancelIngest()
            settle()
            check("no queued copy is added after cancelIngest()", model.history.items.isEmpty, "\(model.history.items.map(\.preview))")
            check("no queued copy writes a blob after cancelIngest()", blobs().isEmpty, "\(blobs())")
            model.ingest(copy("a copy after the restart"))
            settle()
            check("a copy after cancelIngest() is handled again", model.history.items.map(\.preview) == ["a copy after the restart"]
                  && blobs().count == 1, "\(model.history.items.map(\.preview)) \(blobs())")
        }

        let failed = tally.failures
        if failed == 0 { print("all clipboard checks passed") } else { print("\(failed) clipboard check(s) failed") }
        return failed == 0
    }
}

/// The number of failed checks (a class so the nested `check` function can bump it).
private final class Tally {
    var failures = 0
}
