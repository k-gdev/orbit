import AppKit
import OrbitCore

/// Fixture data for the snapshot CLI (`--snapshot-panel clipboard`, `--snapshot-settings-page clipboard`,
/// `--snapshot-clipboard-popup`): a made-up history, a throwaway settings object and a fixed clock. No
/// pasteboard, no disk, no permissions.
@MainActor
enum ClipboardFixtures {
    /// "Now" for fixture relative times.
    static let now = Date(timeIntervalSince1970: 1_793_000_000)

    /// Settings over `SnapshotFixtures.defaults()`: if a snapshot changes a value, the plist lands in a temp
    /// folder (never in ~/Library/Preferences) that is removed when the process exits.
    static func settings(ignoredApps: [String] = []) -> ClipboardSettings {
        let settings = ClipboardSettings(defaults: SnapshotFixtures.defaults())
        if !ignoredApps.isEmpty { settings.ignoredBundleIDs = ignoredApps }
        return settings
    }

    /// A model over a realistic history: text, rich text, an image, copied files, a few pinned entries.
    static func model(settings provided: ClipboardSettings? = nil, empty: Bool = false) -> ClipboardModel {
        let settings = provided ?? Self.settings()
        if empty { return ClipboardModel(fixtureItems: [], thumbnails: [:], settings: settings, now: now) }
        let (items, thumbnails) = historyItems()
        return ClipboardModel(fixtureItems: items, thumbnails: thumbnails, settings: settings, now: now)
    }

    /// Newest first, the order the history stores.
    static func historyItems() -> (items: [ClipboardItem], thumbnails: [UUID: NSImage]) {
        func make(_ capture: ClipboardCapture, ago: TimeInterval, pinned: Bool = false, bytes: Int? = nil) -> ClipboardItem {
            var capture = capture
            capture.date = now.addingTimeInterval(-ago)
            var item = capture.makeItem(payloadFile: nil)
            item.pinned = pinned
            if let bytes { item.byteSize = bytes }
            return item
        }
        let safari = ("com.apple.Safari", "Safari")
        let notes = ("com.apple.Notes", "Notes")
        let terminal = ("com.apple.Terminal", "Terminal")
        let mail = ("com.apple.mail", "Mail")
        let finder = ("com.apple.finder", "Finder")
        let preview = ("com.apple.Preview", "Preview")
        let textEdit = ("com.apple.TextEdit", "TextEdit")
        func text(_ s: String, _ app: (String, String)) -> ClipboardCapture {
            .text(s, sourceBundleID: app.0, sourceName: app.1, date: now)
        }

        let screenshot = make(.image(png: Data(), width: 2560, height: 1440, sourceBundleID: preview.0, sourceName: preview.1, date: now),
                              ago: 11 * 60, bytes: 1_840_000)
        let items = [
            make(text("Can we move the review to Thursday at 3pm? I'll send a new invite once Priya confirms.", mail), ago: 40),
            make(.richText(rtf: Data("{\\rtf1 q3}".utf8), plain: "Q3 summary: revenue up 12 % on the quarter, churn flat at 1.8 %, three new enterprise accounts signed.",
                           sourceBundleID: textEdit.0, sourceName: textEdit.1, date: now), ago: 4 * 60),
            screenshot,
            make(.files(paths: ["/Users/demo/Documents/Invoice-2026-10.pdf", "/Users/demo/Documents/receipt.png"],
                        sourceBundleID: finder.0, sourceName: finder.1, date: now), ago: 26 * 60),
            make(text("https://github.com/k-gdev/orbit/pull/4", safari), ago: 62 * 60),
            make(text("swift build -c release --arch arm64 --arch x86_64", terminal), ago: 3 * 3_600),
            make(text("Café menu: crème brûlée, éclair, tarte au citron", notes), ago: 30 * 3_600),
            make(text("Thanks for reaching out! I'll get back to you within one business day.", mail), ago: 3 * 86_400, pinned: true),
            make(text("hello@example.com", mail), ago: 9 * 86_400, pinned: true),
        ]
        return (items, [screenshot.id: sampleImage()])
    }

    /// A made-up screenshot: a window with a title bar, sidebar and a few content bars.
    static func sampleImage() -> NSImage {
        NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in
            NSGradient(colors: [NSColor(red: 0.36, green: 0.27, blue: 0.62, alpha: 1), NSColor(red: 0.96, green: 0.70, blue: 0.56, alpha: 1)])?
                .draw(in: rect, angle: 35)
            NSColor.white.withAlphaComponent(0.92).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 12, width: 128, height: 66), xRadius: 6, yRadius: 6).fill()
            NSColor(red: 0.84, green: 0.82, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 16, y: 64, width: 128, height: 14), xRadius: 6, yRadius: 6).fill()
            NSColor(red: 0.50, green: 0.39, blue: 0.61, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 44, width: 54, height: 7), xRadius: 3, yRadius: 3).fill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 30, width: 84, height: 7), xRadius: 3, yRadius: 3).fill()
            NSBezierPath(roundedRect: NSRect(x: 26, y: 18, width: 40, height: 7), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}
