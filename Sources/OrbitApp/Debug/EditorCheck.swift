import AppKit
import OrbitCore
import PDFKit
import SwiftUI

/// Hidden command-line mode: opens the real editor panels offscreen-ish (an accessory app, no Dock icon) and checks what the
/// ImageRenderer snapshots cannot see, because they bypass `EditorWindowController.present`:
///
///     Orbit --check-editors <image file> [pdf file]
///
/// - every panel opens with a non-empty frame, visible, on a screen (the zero-height-panel defect);
/// - closing a panel releases its controller (the Markup retain-cycle defect), including a Markup opened through `EditorRouter`;
/// - a failing preview render publishes an error and a later success clears it (Adjust and Add BG).
///
/// - the document and utility editors (Redact, Organize, Split, Metadata, Custom compress) open the same way, and their models
///   build the job parameters the processors expect. The PDF editors use `pdf file`, or a three-page sample written to a
///   fresh temporary folder (removed afterwards) when none is given.
///
/// Prints one line per check and exits 0 when all pass, 1 otherwise. Needs a logged-in GUI session.
enum EditorCheck {
    static let flag = "--check-editors"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        guard arguments.indices.contains(start + 1) else {
            FileHandle.standardError.write(Data("usage: Orbit --check-editors <image file> [pdf file]\n".utf8))
            exit(64)
        }
        let url = URL(fileURLWithPath: arguments[start + 1])
        let pdfArgument = arguments.indices.contains(start + 2) ? URL(fileURLWithPath: arguments[start + 2]) : nil
        NSApplication.shared.setActivationPolicy(.accessory)
        let checker = Checker()
        run(url, check: checker)
        if let pdfArgument {
            runDocumentEditors(pdf: pdfArgument, image: url, isSample: false, check: checker)
        } else if let sample = SamplePDF.make() {
            runDocumentEditors(pdf: sample.pdf, image: url, isSample: true, check: checker)
            try? FileManager.default.removeItem(at: sample.folder)
        } else {
            checker("write the sample PDF", false)
        }
        print(checker.failures == 0 ? "all editor checks passed" : "\(checker.failures) editor check(s) failed")
        exit(checker.failures == 0 ? 0 : 1)
    }

    final class Checker {
        private(set) var failures = 0

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            if !ok { failures += 1 }
        }
    }

    @MainActor
    private static func spin(until condition: () -> Bool, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    private static func settle() { spin(until: { false }, timeout: 0.3) }

    @MainActor
    private static func run(_ url: URL, check: Checker) {
        let item = DroppedItem(url: url)

        // Markup, through the router (the path the app takes).
        var markupSubmissions = 0
        weak var markup: EditorWindowController?
        autoreleasepool {
            let controller = EditorRouter.openMarkup([item], index: 0, action: .tool(.markup, nil), options: { JobOptions() },
                                                     submit: { _ in markupSubmissions += 1 }, center: nil)
            markup = controller
            settle()
            checkPanel("markup", controller, check)
            controller.close()
        }
        settle()
        check("markup controller released after close (no retain cycle)", markup == nil)

        // Adjust and Add BG, presented as the router presents them.
        weak var adjust: EditorWindowController?
        let adjustModel = AdjustModel()
        autoreleasepool {
            let controller = EditorWindowController.present(width: ImageAdjustEditor.width, content: { close, _ in
                ImageAdjustEditor(title: "Adjust Photo", model: adjustModel, onClose: close, onApply: { _ in })
            })
            adjust = controller
            settle()
            checkPanel("adjust", controller, check)
            controller.close()
        }
        settle()
        check("adjust controller released after close", adjust == nil)

        weak var background: EditorWindowController?
        let backgroundModel = BackgroundModel()
        autoreleasepool {
            let controller = EditorWindowController.present(width: AddBackgroundEditor.width, content: { close, _ in
                AddBackgroundEditor(title: "Add Background", model: backgroundModel, onClose: close, onApply: { _ in })
            })
            background = controller
            settle()
            checkPanel("addbg", controller, check)
            controller.close()
        }
        settle()
        check("addbg controller released after close", background == nil)

        // Preview failures are published, not swallowed.
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let adjustProbe = AdjustModel()
        adjustProbe.renderer = { _, _ in throw Boom() }
        if let image = try? EditorImage.load(url) {
            adjustProbe.image = image
            adjustProbe.scheduleRender()
            spin(until: { adjustProbe.previewError != nil })
            check("adjust: a failing render publishes previewError", adjustProbe.previewError?.contains("boom") == true,
                  adjustProbe.previewError ?? "nil")
            adjustProbe.renderer = { try AdjustRenderer.render($0, $1) }
            adjustProbe.scheduleRender()
            spin(until: { adjustProbe.previewError == nil && adjustProbe.preview != nil })
            check("adjust: a later success clears previewError and sets the preview",
                  adjustProbe.previewError == nil && adjustProbe.preview != nil)

            let backgroundProbe = BackgroundModel()
            backgroundProbe.composer = { _, _, _ in throw Boom() }
            backgroundProbe.set(image: image, subject: image.proxy)
            backgroundProbe.scheduleRender()
            spin(until: { backgroundProbe.previewError != nil })
            check("addbg: a failing render publishes previewError", backgroundProbe.previewError?.contains("boom") == true,
                  backgroundProbe.previewError ?? "nil")
            backgroundProbe.composer = { try BackgroundComposer.compose(subject: $0, original: $1, style: $2) }
            backgroundProbe.scheduleRender()
            spin(until: { backgroundProbe.previewError == nil && backgroundProbe.preview != nil })
            check("addbg: a later success clears previewError and sets the preview",
                  backgroundProbe.previewError == nil && backgroundProbe.preview != nil)
        } else {
            check("load \(url.lastPathComponent) for the preview checks", false)
        }
    }

    // MARK: Document and utility editors

    @MainActor
    private static func runDocumentEditors(pdf: URL, image: URL, isSample: Bool, check: Checker) {
        func opens<V: View>(_ name: String, width: CGFloat, _ content: @escaping (_ close: @escaping () -> Void) -> V) {
            weak var released: EditorWindowController?
            autoreleasepool {
                let controller = EditorWindowController.present(width: width, content: { close, _ in content(close) })
                released = controller
                settle()
                checkPanel(name, controller, check)
                controller.close()
            }
            settle()
            check("\(name) controller released after close", released == nil)
        }

        let redact = RedactModel()
        redact.load(pdf)
        opens("redact", width: PDFRedactEditor.width) { PDFRedactEditor(title: "Redact", model: redact, onClose: $0, onApply: { _ in }) }

        let organize = OrganizeModel()
        let split = SplitModel()
        let metadata = MetadataModel(allowsArtwork: true, loader: { ImageMetadata.read($0) })
        metadata.load(image)
        let compress = CompressCustomModel()
        compress.load(image)
        if let document = PDFDocument(url: pdf) {
            organize.set(document: document)
            split.set(pageCount: document.pageCount)
        }
        opens("organize", width: PDFOrganizeEditor.width) { PDFOrganizeEditor(title: "Organize Pages", model: organize, onClose: $0, onApply: { _ in }) }
        opens("split", width: PDFSplitEditor.width) { PDFSplitEditor(title: "Split PDF", model: split, onClose: $0, onApply: { _ in }) }
        opens("metadata", width: MetadataEditor.width) {
            MetadataEditor(title: "Metadata", model: metadata, onClose: $0, onApply: { _ in }, onRemoveLocation: {})
        }
        opens("compress", width: CompressCustomPanel.width) { CompressCustomPanel(title: "Compress", model: compress, onClose: $0, onApply: { _ in }) }

        checkRedactModel(pdf, check)
        if isSample { checkRedactRotationAndCrop(pdf, check) }
        checkRedactOverlayScroll(pdf, check)
        checkOrganizeModel(pdf, check)
        checkSplitModel(check)
        checkMetadataModel(image, check)
        checkCompressModel(check)
    }

    /// Redact Selection on a live `PDFView` selection, and the grouping of marks into `PDFRedaction`s.
    @MainActor
    private static func checkRedactModel(_ pdf: URL, _ check: Checker) {
        let model = RedactModel()
        model.load(pdf)
        let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
        view.document = model.document
        model.pdfView = view
        guard let document = model.document else { return check("redact: open the PDF", false) }
        let hits = document.findString("Account", withOptions: [])
        check("redact: the sample text is found", !hits.isEmpty)
        view.setCurrentSelection(hits.first, animate: false)
        model.redactSelection()
        let first = model.marks.first
        check("redact: Redact Selection marks the selected line", model.marks.count >= 1 && first?.pageIndex == 0,
              "\(model.marks.count) marks")
        if let first, let page = document.page(at: first.pageIndex) {
            check("redact: the mark is inside the page, in page space", page.bounds(for: .cropBox).contains(first.rect), "\(first.rect)")
            check("redact: the mark is drawn as a page annotation", page.annotations.contains { $0 === first.annotation })
        }
        let last = 2
        if let page = document.page(at: last) {
            model.add(page: page, rect: CGRect(x: 10, y: 10, width: 50, height: 20))
            model.add(page: page, rect: CGRect(x: -500, y: -500, width: 5, height: 5))
        }
        let groups = model.redactions
        check("redact: marks group per page, in page order",
              groups.map(\.pageIndex) == [0, last] && groups.last?.rects == [CGRect(x: 10, y: 10, width: 50, height: 20)], "\(groups)")
        let count = model.marks.count
        model.undo()
        check("redact: Undo removes the last mark and its annotation",
              model.marks.count == count - 1 && document.page(at: last)?.annotations.isEmpty == true)
    }

    /// Redact Selection on a rotated page and on a page whose crop box is offset from the media box. Convention (the
    /// one Task 22's rasterizer must use): a redaction rect is in PDFKit page space, which is the page's *unrotated*
    /// media-box coordinate system (points, origin at the media box's bottom left, `/Rotate` and crop box not applied).
    /// The sample draws its text at a known unrotated position, so the expected region does not come from PDFKit.
    @MainActor
    private static func checkRedactRotationAndCrop(_ pdf: URL, _ check: Checker) {
        guard let document = PDFDocument(url: pdf), document.pageCount > SamplePDF.croppedPage else {
            return check("redact geometry: the five-page sample is available", false)
        }
        let drawn = CGRect(x: 72, y: 652, width: 50, height: 10) // inside "Account", unrotated media space
        for (name, index) in [("rotated", SamplePDF.rotatedPage), ("cropped", SamplePDF.croppedPage)] {
            guard let page = document.page(at: index) else { check("redact \(name): page exists", false); continue }
            let model = RedactModel()
            model.open(document)
            let view = PDFView(frame: NSRect(x: 0, y: 0, width: 400, height: 500))
            view.document = document
            model.pdfView = view
            guard let hit = document.findString("Account", withOptions: []).first(where: { $0.pages.contains(page) }) else {
                check("redact \(name): the sample text is found", false); continue
            }
            view.setCurrentSelection(hit, animate: false)
            model.redactSelection()
            check("redact \(name): the page keeps its geometry (rotation \(page.rotation), crop \(page.bounds(for: .cropBox)))",
                  index == SamplePDF.rotatedPage ? page.rotation == 90 : page.bounds(for: .cropBox) == SamplePDF.cropBox)
            guard let mark = model.marks.first(where: { $0.pageIndex == index }) else {
                check("redact \(name): Redact Selection marks the line", false); continue
            }
            check("redact \(name): the mark covers the text drawn at a known position", mark.rect.contains(drawn), "\(mark.rect)")
            check("redact \(name): the mark is inside the crop box", page.bounds(for: .cropBox).contains(mark.rect), "\(mark.rect)")
            // What the person sees: the displayed (rotated / cropped) page is black across the whole mark. The text itself is
            // black too, so this compares against the same region without the mark.
            let region = mark.rect.insetBy(dx: 2, dy: 2)
            let covered = darkFraction(page, in: region)
            model.undo()
            let bare = darkFraction(page, in: region)
            check("redact \(name): the black box covers the text on the displayed page", covered >= 0.95 && bare < 0.9,
                  "with mark \(covered), without \(bare)")
        }
    }

    /// Fraction of a grid of points over `region` (unrotated media space) that are nearly black in the page's thumbnail
    /// (annotations included), after turning the points clockwise by the page rotation and shifting by the crop box.
    @MainActor
    private static func darkFraction(_ page: PDFPage, in region: CGRect) -> Double {
        let crop = page.bounds(for: .cropBox)
        let rotation = page.rotation % 360
        let displayed = rotation % 180 == 0 ? crop.size : CGSize(width: crop.height, height: crop.width)
        let image = page.thumbnail(of: CGSize(width: displayed.width * 2, height: displayed.height * 2), for: .cropBox)
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        let scaleX = CGFloat(bitmap.pixelsWide) / displayed.width, scaleY = CGFloat(bitmap.pixelsHigh) / displayed.height
        var dark = 0, total = 0
        for i in 0..<12 {
            for j in 0..<4 {
                let x = region.minX + region.width * (CGFloat(i) + 0.5) / 12 - crop.minX
                let y = region.minY + region.height * (CGFloat(j) + 0.5) / 4 - crop.minY
                let (dx, dy): (CGFloat, CGFloat) = switch rotation {
                case 90: (y, crop.width - x)
                case 180: (crop.width - x, crop.height - y)
                case 270: (crop.height - y, x)
                default: (x, y)
                }
                total += 1
                guard let color = bitmap.colorAt(x: Int(dx * scaleX), y: Int((displayed.height - dy) * scaleY))?
                    .usingColorSpace(.deviceRGB) else { continue }
                if color.redComponent < 0.15 && color.greenComponent < 0.15 && color.blueComponent < 0.15 { dark += 1 }
            }
        }
        return Double(dark) / Double(total)
    }

    /// Draw Box mode: the overlay claims the mouse, but the scroll wheel must still reach the page view.
    @MainActor
    private static func checkRedactOverlayScroll(_ pdf: URL, _ check: Checker) {
        guard let document = PDFDocument(url: pdf) else { return check("redact scroll: open the PDF", false) }
        let container = RedactContainer(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(contentRect: container.frame, styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = container
        container.pdfView.document = document
        container.layoutSubtreeIfNeeded()
        container.overlay.isDrawing = true
        spin(until: { false }, timeout: 0.5)
        guard let scrollView = container.pdfView.firstDescendant(ofType: NSScrollView.self) else {
            return check("redact scroll: the page view has a scroll view", false)
        }
        check("redact scroll: Draw Box takes the mouse", container.overlay.hitTest(NSPoint(x: 100, y: 100)) === container.overlay)
        spin(until: { false }, timeout: 0.5)
        let before = scrollView.contentView.bounds.origin
        guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -150, wheel2: 0, wheel3: 0),
              let event = NSEvent(cgEvent: cgEvent) else { return check("redact scroll: build a scroll event", false) }
        container.overlay.scrollWheel(with: event)
        spin(until: { false }, timeout: 0.3)
        let after = scrollView.contentView.bounds.origin
        check("redact scroll: the wheel scrolls the page view while drawing", after != before, "\(before) -> \(after)")
    }

    @MainActor
    private static func checkOrganizeModel(_ pdf: URL, _ check: Checker) {
        guard let document = PDFDocument(url: pdf), document.pageCount >= 3 else { return check("organize: open the PDF", false) }
        let model = OrganizeModel()
        model.set(document: document)
        check("organize: untouched pages are not a change", !model.changed)
        for index in 0..<document.pageCount { model.move(index, to: 0) }
        check("organize: reversing gives the reversed order",
              model.operations.map(\.sourceIndex) == Array((0..<document.pageCount).reversed()))
        for _ in 0..<4 { model.rotate(0) }
        check("organize: four turns are no turn", model.operations.allSatisfy { $0.quarterTurns == 0 })
        model.rotate(1)
        model.remove(2)
        let ops = model.operations
        check("organize: rotate and delete show in the operations",
              ops.count == document.pageCount - 1 && ops.first(where: { $0.sourceIndex == 1 })?.quarterTurns == 1
                  && !ops.contains { $0.sourceIndex == 2 }, "\(ops)")
        model.resetAll()
        check("organize: Reset restores the source order", !model.changed && model.pages.count == document.pageCount)
    }

    @MainActor
    private static func checkSplitModel(_ check: Checker) {
        let model = SplitModel()
        model.set(pageCount: 3)
        check("split: empty text gives no ranges and no error", model.ranges == nil && !model.isInvalid)
        model.text = "1-2, 3"
        check("split: valid text gives ranges", model.ranges == [1...2, 3...3])
        model.text = "1-9"
        check("split: out-of-range text is invalid", model.ranges == nil && model.isInvalid)
    }

    @MainActor
    private static func checkMetadataModel(_ image: URL, _ check: Checker) {
        let fields = [MetadataField(key: .artist, label: "Artist", value: "A", editable: true),
                      MetadataField(key: .copyright, label: "Copyright", value: "", editable: true),
                      MetadataField(key: .cameraMake, label: "Camera make", value: "Apple", editable: false)]
        let model = MetadataModel(allowsArtwork: true, loader: { _ in fields })
        model.load(image)
        check("metadata: the loader's fields are shown", model.fields == fields)
        check("metadata: nothing changed gives no edits", model.edits.isEmpty)
        model.drafts[.artist] = " B "
        model.drafts[.cameraMake] = "Other"
        check("metadata: only changed editable fields are edits, trimmed", model.edits == ["artist": "B"], "\(model.edits)")
        model.drafts[.artist] = ""
        check("metadata: clearing a field is an empty edit", model.edits == ["artist": ""])
        model.artwork = URL(fileURLWithPath: "/tmp/art.jpg")
        check("metadata: artwork goes in the edits under 'artwork'", model.edits["artwork"] == "/tmp/art.jpg")
    }

    @MainActor
    private static func checkCompressModel(_ check: Checker) {
        let model = CompressCustomModel()
        check("compress: no size, no percent target", model.target == nil)
        model.set(originalBytes: 1_000_000)
        model.percent = 60
        check("compress: 60% smaller than 1 MB is under 400 KB", model.target == .fitUnder(400_000), "\(String(describing: model.target))")
        model.mode = .size
        model.amount = 2
        model.unit = .megabytes
        check("compress: 2 MB is 2,000,000 bytes", model.target == .fitUnder(2_000_000))
        model.amount = 0
        check("compress: zero is not a target", model.target == nil)

        // A batch: percent mode gives each file its own target; Under size is one job for all of them.
        let items = [1_000_000, 10_000_000, 500_000].enumerated().map { index, _ in
            DroppedItem(url: URL(fileURLWithPath: "/tmp/orbit-check-\(index).png"))
        }
        let batch = CompressCustomModel()
        batch.set(sizes: [1_000_000, 10_000_000, 500_000])
        batch.mode = .percent
        batch.percent = 60
        let perFile = EditorRouter.compressRequests(batch.jobs, items: items, action: .tool(.compress, nil),
                                                    options: JobOptions())
        check("compress batch: percent mode submits one request per file, each with its own target",
              perFile.map(\.parameters) == [.compress(.fitUnder(400_000)), .compress(.fitUnder(4_000_000)), .compress(.fitUnder(200_000))]
                  && perFile.allSatisfy { $0.items.count == 1 }, "\(perFile.map(\.parameters))")
        check("compress batch: each request holds its own file", perFile.map { $0.items.first?.url } == items.map(\.url))
        batch.mode = .size
        batch.amount = 300
        batch.unit = .kilobytes
        let together = EditorRouter.compressRequests(batch.jobs, items: items, action: .tool(.compress, nil),
                                                     options: JobOptions())
        check("compress batch: Under size is one request holding every file",
              together.count == 1 && together.first?.items.count == 3 && together.first?.parameters == .compress(.fitUnder(300_000)))
    }

    @MainActor
    private static func checkPanel(_ name: String, _ controller: EditorWindowController,
                                   _ check: Checker) {
        let frame = controller.frame
        check("\(name): panel frame is non-empty", frame.width >= 1 && frame.height >= EditorGeometry.minimumPanelHeight, "\(frame)")
        check("\(name): panel is visible", controller.isVisible)
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        check("\(name): panel is on a screen", onScreen || NSScreen.screens.isEmpty, "\(frame)")
    }
}

/// A five-page text PDF in a fresh temporary folder, for the checks when no PDF is given. Pages 1-3 are plain
/// 612x792 pages; page 4 has `/Rotate 90`; page 5 has a crop box that is smaller than the media box and does not
/// start at the origin. Every page has "Account ..." drawn with its baseline at (72, 650) in unrotated media space.
private enum SamplePDF {
    static let rotatedPage = 3
    static let croppedPage = 4
    static let cropBox = CGRect(x: 40, y: 600, width: 400, height: 150)

    static func make() -> (folder: URL, pdf: URL)? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("orbit-editor-check-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil else { return nil }
        let url = folder.appendingPathComponent("sample.pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return nil }
        for page in 1...5 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            NSString(string: "Page \(page)").draw(at: CGPoint(x: 72, y: 700), withAttributes: [.font: NSFont.boldSystemFont(ofSize: 28)])
            NSString(string: "Account 1234-5678 belongs to J. Smith.")
                .draw(at: CGPoint(x: 72, y: 650), withAttributes: [.font: NSFont.systemFont(ofSize: 14)])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(url: url), document.pageCount == 5 else { return nil }
        document.page(at: rotatedPage)?.rotation = 90
        document.page(at: croppedPage)?.setBounds(cropBox, for: .cropBox)
        guard document.write(to: url) else { return nil }
        return (folder, url)
    }
}
