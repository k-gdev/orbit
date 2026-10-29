import AppKit
import OrbitCore
import PDFKit
import SwiftUI

/// Hidden command-line mode (rulings R21/R22): renders an image editor offscreen to a PNG.
///
///     Orbit --snapshot-editor <markup|adjust|addbg|metadata|compress> <image file> <out.png> [--replace] [--tool crop|resize|arrow|text|blackout]
///     Orbit --snapshot-editor <redact|organize|split> <pdf file> <out.png> [--replace]
///     Orbit --snapshot-editor <trim|msplit|snapshot|crop> <video file> <out.png> [--replace] [--tool free|1:1|4:3|16:9|9:16]
///     Orbit --snapshot-editor <trim|msplit|bleep> <audio file> <out.png> [--replace]
///
/// Uses sample edits on the given file and a flat glass stand-in; refuses to overwrite a PNG unless `--replace`.
enum EditorSnapshot {
    static let flag = "--snapshot-editor"
    static let kinds = ["markup", "adjust", "addbg", "metadata", "compress", "redact", "organize", "split",
                        "trim", "msplit", "snapshot", "bleep", "crop"]
    static let usage = "usage: Orbit --snapshot-editor <\(kinds.joined(separator: "|"))> <file> <out.png> [--replace] [--tool <name>]"

    struct Failure: Error, CustomStringConvertible { let description: String }

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        let args = Array(arguments[(start + 1)...])
        guard args.count >= 3, kinds.contains(args[0]) else {
            FileHandle.standardError.write(Data("\(usage)\n".utf8))
            exit(64)
        }
        let input = URL(fileURLWithPath: args[1]), output = URL(fileURLWithPath: args[2])
        let replace = args.dropFirst(3).contains("--replace")
        let tool = args.firstIndex(of: "--tool").flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
        NSApplication.shared.setActivationPolicy(.prohibited)
        do {
            try render(kind: args[0], image: input, to: output, replace: replace, tool: tool)
            print("wrote \(output.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("snapshot failed: \(error)\n".utf8))
            exit(1)
        }
    }

    @MainActor
    static func render(kind: String, image url: URL, to output: URL, replace: Bool, tool: String? = nil) throws {
        guard output.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if FileManager.default.fileExists(atPath: output.path), !replace {
            throw Failure(description: "\(output.path) exists (pass --replace to overwrite it)")
        }
        let editor: AnyView
        let width: CGFloat
        switch kind {
        case "markup":
            editor = AnyView(ImageMarkupEditor(title: "Markup", model: try markupModel(url, tool: tool), onClose: {}, onApply: { _ in }))
            width = ImageMarkupEditor.width
        case "adjust":
            editor = AnyView(ImageAdjustEditor(title: "Adjust Photo", model: try adjustModel(url), onClose: {}, onApply: { _ in }))
            width = ImageAdjustEditor.width
        case "addbg":
            editor = AnyView(AddBackgroundEditor(title: "Add Background", model: try backgroundModel(url), onClose: {}, onApply: { _ in }))
            width = AddBackgroundEditor.width
        case "metadata":
            let model = MetadataModel(allowsArtwork: false, loader: { ImageMetadata.read($0) })
            model.set(fields: ImageMetadata.read(url))
            model.drafts[.artist] = "Demo Artist"
            editor = AnyView(MetadataEditor(title: "Metadata", model: model, onClose: {}, onApply: { _ in }, onRemoveLocation: {}))
            width = MetadataEditor.width
        case "compress":
            let model = CompressCustomModel()
            model.load(url)
            model.percent = 60
            editor = AnyView(CompressCustomPanel(title: "Compress", model: model, onClose: {}, onApply: { _ in }))
            width = CompressCustomPanel.width
        case "redact":
            let model = RedactModel()
            model.load(url)
            // One box over the second text line of the sample PDF (page space, origin bottom left).
            if let page = model.document?.page(at: 0) {
                let bounds = page.bounds(for: .cropBox)
                model.addForSnapshot(pageIndex: 0, rect: CGRect(x: bounds.minX + 70, y: bounds.maxY - 168, width: 300, height: 20))
            }
            editor = AnyView(PDFRedactEditor(title: "Redact", model: model, onClose: {}, onApply: { _ in }))
            width = PDFRedactEditor.width
        case "organize":
            let model = OrganizeModel()
            guard let document = PDFDocument(url: url) else { throw Failure(description: "can't read \(url.path)") }
            model.set(document: document)
            // Reversed, with one page turned.
            for index in 0..<document.pageCount { model.move(index, to: 0) }
            if let first = model.pages.first { model.rotate(first.id) }
            editor = AnyView(PDFOrganizeEditor(title: "Organize Pages", model: model, onClose: {}, onApply: { _ in }))
            width = PDFOrganizeEditor.width
        case "trim", "msplit", "snapshot", "bleep":
            let (model, title) = try mediaRangeModel(kind, url)
            editor = AnyView(MediaRangeEditor(title: title, model: model, onClose: {}, onApply: { _ in }))
            width = MediaRangeEditor.width
        case "crop":
            editor = AnyView(VideoCropEditor(title: "Crop Video", model: try cropModel(url, aspect: tool), onClose: {}, onApply: { _ in }))
            width = VideoCropEditor.width
        default:
            guard let document = PDFDocument(url: url) else { throw Failure(description: "can't read \(url.path)") }
            let model = SplitModel()
            model.set(pageCount: document.pageCount)
            model.text = "1-2, 4"
            editor = AnyView(PDFSplitEditor(title: "Split PDF", model: model, onClose: {}, onApply: { _ in }))
            width = PDFSplitEditor.width
        }
        let view = editor
            .frame(width: width)
            .padding(40)
            .background(LinearGradient(colors: [Color(red: 0.94, green: 0.70, blue: 0.23), Color(red: 1.0, green: 0.42, blue: 0.33),
                                                Color(red: 0.66, green: 0.61, blue: 0.85)],
                                       startPoint: .topTrailing, endPoint: .bottomLeading))
            .environment(\.glassRendering, .flat)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let rendered = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: rendered).representation(using: .png, properties: [:]) else {
            throw Failure(description: "rendering failed")
        }
        try png.write(to: output, options: replace ? .atomic : .withoutOverwriting)
    }

    // MARK: Sample edits

    @MainActor
    private static func markupModel(_ url: URL, tool: String?) throws -> MarkupModel {
        let image = try EditorImage.load(url)
        let model = MarkupModel()
        model.set(image: image)
        let w = image.pixelSize.width, h = image.pixelSize.height
        let red = RGBA(r: 1, g: 0.23, b: 0.19, a: 1)
        model.tool = .arrow
        let line = 6 * max(max(w, h) / 1000, 0.6)
        model.setElements([
            .box(CGRect(x: w * 0.12, y: h * 0.40, width: w * 0.30, height: h * 0.30), color: red, width: line),
            .arrow(from: CGPoint(x: w * 0.40, y: h * 0.25), to: CGPoint(x: w * 0.30, y: h * 0.42), color: red, width: line),
            .step(1, at: CGPoint(x: w * 0.12, y: h * 0.40), color: red),
            .text("Look here", at: CGPoint(x: w * 0.42, y: h * 0.18), size: 34 * max(max(w, h) / 1000, 0.6), color: red),
            .blackout(CGRect(x: w * 0.62, y: h * 0.62, width: w * 0.24, height: h * 0.14)),
        ])
        model.setAspect(CropAspect.all[1])
        switch tool {
        case "resize": model.tool = .resize; model.setResize(percent: 50)
        case "arrow": model.tool = .arrow
        case "text": model.tool = .text
        case "blackout": model.tool = .blackout
        default: model.tool = .crop
        }
        return model
    }

    @MainActor
    private static func adjustModel(_ url: URL) throws -> AdjustModel {
        let model = AdjustModel()
        model.image = try EditorImage.load(url)
        model.settings = AdjustSettings(exposure: 0.3, contrast: 1.1, saturation: 1.25, warmth: 0.2)
        model.renderNow()
        return model
    }

    @MainActor
    private static func backgroundModel(_ url: URL) throws -> BackgroundModel {
        let image = try EditorImage.load(url)
        let subject = image.hasTransparency ? image.proxy : try EditorImage.make(from: BackgroundRemover.cutout(url)).proxy
        let model = BackgroundModel()
        model.set(image: image, subject: subject)
        model.mode = .gradient
        model.renderNow()
        return model
    }

    // MARK: Media editors

    /// Runs the main run loop until `condition` holds (the sessions load asynchronously and `ImageRenderer` draws once).
    @MainActor
    private static func spin(until condition: () -> Bool, timeout: TimeInterval = 60) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    private static func session(_ url: URL, stills: Bool) -> MediaSession {
        let ffmpeg = HelperLocator().locate(customFFmpegPath: nil).ffmpeg.map { FFmpeg(executable: $0) }
        let session = MediaSession(item: DroppedItem(url: url), ffmpeg: ffmpeg)
        session.generatesStills = stills
        return session
    }

    /// The Trim, Split, Snapshot or Bleep editor with sample edits: a trimmed middle, two split points, a bleep range.
    @MainActor
    private static func mediaRangeModel(_ kind: String, _ url: URL) throws -> (MediaRangeModel, String) {
        let mode: MediaEditMode = switch kind {
        case "trim": .trim
        case "msplit": .split
        case "snapshot": .snapshot
        default: .bleep
        }
        let session = session(url, stills: true)
        let model = MediaRangeModel(session: session, mode: mode)
        var loaded = false
        Task { await model.load(); loaded = true }
        spin(until: { loaded })
        guard case .ready = session.status else { throw Failure(description: "can't open \(url.lastPathComponent) (\(session.status))") }
        let d = session.duration
        switch mode {
        case .trim:
            model.setStart(d * 0.2)
            model.setEnd(d * 0.75)
            session.seek(to: d * 0.45)
        case .split:
            model.splitEvenly(into: 3)
            session.seek(to: d * 0.5)
        case .snapshot:
            session.seek(to: d * 0.4)
        case .bleep:
            model.setStart(d * 0.2)
            model.setEnd(d * 0.3)
            model.addRange()
            model.setStart(d * 0.6)
            model.setEnd(d * 0.7)
            session.seek(to: d * 0.65)
        }
        if !session.isAudio { spin(until: { false }, timeout: 1.5) }
        let kindName = session.isAudio ? "Audio" : "Video"
        return (model, model.title(for: kindName))
    }

    @MainActor
    private static func cropModel(_ url: URL, aspect: String?) throws -> CropModel {
        let session = session(url, stills: true)
        let model = CropModel(session: session)
        var loaded = false
        Task { await model.load(); loaded = true }
        spin(until: { loaded })
        guard case .ready = session.status, session.videoSize != nil else {
            throw Failure(description: "can't open \(url.lastPathComponent) as a video (\(session.status))")
        }
        session.seek(to: session.duration * 0.3)
        if let option = VideoCropAspect.all.first(where: { $0.title.lowercased() == aspect?.lowercased() || ($0.ratio == nil && aspect == "free") }) {
            model.setAspect(option)
        } else {
            // Like the hero frame: the full width, 62% of the height.
            model.setHeightPercent(62)
        }
        spin(until: { false }, timeout: 1.5)
        return model
    }
}
