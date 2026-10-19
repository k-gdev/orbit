import AppKit
import OrbitCore

/// Opens the editor a slice asks for: Choose…, the image editors (Markup, Adjust, Add BG), the document and utility
/// editors (Redact, Organize, Split, Metadata, Custom compress) and the media editors (Trim, Split, Snapshot, Crop, Bleep).
@MainActor
enum EditorRouter {
    static let notBuilt = "This editor isn't built yet."

    static func open(_ kind: EditorKind, items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        switch kind {
        case .chooseFolder:
            guard case .action(let id, _) = action else {
                coordinator.showError(notBuilt)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            NSApp.activate()
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let request = JobRequest(items: items, action: .action(id, .folder(folder)),
                                     options: coordinator.settings.jobOptions)
            coordinator.run(request, near: NSEvent.mouseLocation)
        case .imageMarkup:
            let images = imageItems(in: items)
            guard !images.isEmpty else { return coordinator.showError(notBuilt) }
            openMarkup(images, index: 0, action: action, options: { coordinator.settings.jobOptions },
                       submit: { coordinator.run($0, near: NSEvent.mouseLocation) }, center: nil)
        case .imageAdjust:
            openAdjust(items, action: action, coordinator: coordinator)
        case .addBackground:
            openAddBackground(items, action: action, coordinator: coordinator)
        case .pdfRedact:
            openRedact(items, action: action, coordinator: coordinator)
        case .pdfOrganize:
            openOrganize(items, action: action, coordinator: coordinator)
        case .pdfSplit:
            openSplit(items, action: action, coordinator: coordinator)
        case .metadataEdit:
            openMetadata(items, action: action, coordinator: coordinator)
        case .compressCustom:
            openCompressCustom(items, action: action, coordinator: coordinator)
        case .mediaTrim:
            openMedia(items, mode: .trim, action: action, coordinator: coordinator)
        case .mediaSplit:
            openMedia(items, mode: .split, action: action, coordinator: coordinator)
        case .videoSnapshot:
            openMedia(items, mode: .snapshot, action: action, coordinator: coordinator)
        case .audioBleep:
            openMedia(items, mode: .bleep, action: action, coordinator: coordinator)
        case .videoCrop:
            if openVideoCrop(items, action: action, host: mediaHost(coordinator)) == nil { coordinator.showError(notBuilt) }
        }
    }

    // MARK: Image editors

    private static func imageItems(in items: [DroppedItem]) -> [DroppedItem] { items.filter { $0.category == .image } }

    /// Markup is per image (its marks, crop and size are in that image's pixels): with several images the
    /// editor opens for each in turn, in the same place, after Apply. Closing it with × stops the run.
    /// `submit` runs the job (the coordinator's `run`); the live check passes a recorder.
    @discardableResult
    static func openMarkup(_ images: [DroppedItem], index: Int, action: SliceAction, options: @escaping () -> JobOptions,
                           submit: @escaping (JobRequest) -> Void, center: CGPoint?) -> EditorWindowController {
        let item = images[index]
        let model = MarkupModel()
        let next = Box<CGPoint?>(nil)
        let title = images.count > 1 ? "Markup \(index + 1) of \(images.count)" : "Markup"
        // Nothing here may hold the controller strongly: the hosting view (owned by the controller's panel) keeps these
        // closures, so a strong reference would leak the controller, panel, model and proxy on every session.
        let controller = EditorWindowController.present(width: ImageMarkupEditor.width, center: center, onClose: {
            if let point = next.value, index + 1 < images.count {
                openMarkup(images, index: index + 1, action: action, options: options, submit: submit, center: point)
            }
        }, content: { close, center in
            ImageMarkupEditor(title: title, model: model, onClose: close, onApply: { document in
                submit(JobRequest(items: [item], action: action, parameters: .markup(document), options: options()))
                next.value = center()
                close()
            })
        })
        Task { await model.load(item.url) }
        return controller
    }

    private static func openAdjust(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        let images = imageItems(in: items)
        guard let first = images.first else { return coordinator.showError(notBuilt) }
        let model = AdjustModel()
        let title = images.count > 1 ? "Adjust \(images.count) Photos" : "Adjust Photo"
        EditorWindowController.present(width: ImageAdjustEditor.width, content: { close, _ in
            ImageAdjustEditor(title: title, model: model, onClose: close, onApply: { settings in
                let request = JobRequest(items: images, action: action, parameters: .adjust(settings),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
        Task { await model.load(first.url) }
    }

    private static func openAddBackground(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        let images = imageItems(in: items)
        guard let first = images.first else { return coordinator.showError(notBuilt) }
        let model = BackgroundModel()
        let title = images.count > 1 ? "Add Background to \(images.count)" : "Add Background"
        EditorWindowController.present(width: AddBackgroundEditor.width, content: { close, _ in
            AddBackgroundEditor(title: title, model: model, onClose: close, onApply: { style in
                let request = JobRequest(items: images, action: action, parameters: .background(style),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
        Task { await model.load(first.url) }
    }

    // MARK: Document and utility editors

    private static func firstPDF(in items: [DroppedItem]) -> DroppedItem? { items.first { $0.category == .pdf } }

    private static func openRedact(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = firstPDF(in: items) else { return coordinator.showError(notBuilt) }
        let model = RedactModel()
        EditorWindowController.present(width: PDFRedactEditor.width, content: { close, _ in
            PDFRedactEditor(title: "Redact", model: model, onClose: close, onApply: { redactions in
                let request = JobRequest(items: [item], action: action, parameters: .pdfRedactions(redactions),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
        model.load(item.url)
    }

    private static func openOrganize(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = firstPDF(in: items) else { return coordinator.showError(notBuilt) }
        let model = OrganizeModel()
        EditorWindowController.present(width: PDFOrganizeEditor.width, content: { close, _ in
            PDFOrganizeEditor(title: "Organize Pages", model: model, onClose: close, onApply: { operations in
                let request = JobRequest(items: [item], action: action, parameters: .pdfPages(operations),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
        Task { await model.load(item.url) }
    }

    private static func openSplit(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = firstPDF(in: items) else { return coordinator.showError(notBuilt) }
        let model = SplitModel()
        EditorWindowController.present(width: PDFSplitEditor.width, content: { close, _ in
            PDFSplitEditor(title: "Split PDF", model: model, onClose: close, onApply: { ranges in
                let request = JobRequest(items: [item], action: action, parameters: .pdfRanges(ranges),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
        Task { await model.load(item.url) }
    }

    /// Reads audio tags for the Metadata editor, through ffmpeg for formats AVFoundation can't read (when it is installed).
    /// `AudioMetadata.read` is async, so this is async too.
    static var audioMetadataLoader: (@Sendable (URL, FFmpeg?) async -> [MetadataField])? = { url, ffmpeg in
        await AudioMetadata.read(url, ffmpeg: ffmpeg)
    }

    private static func openMetadata(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = items.first else { return coordinator.showError(notBuilt) }
        switch item.category {
        case .image:
            let model = MetadataModel(allowsArtwork: false, loader: { ImageMetadata.read($0) })
            model.load(item.url)
            presentMetadata(model, item: item, action: action, coordinator: coordinator)
        case .audio:
            guard let loader = audioMetadataLoader else {
                return coordinator.showError("Editing audio metadata isn't available yet.")
            }
            // The panel is sized once, from its content, so the tags are read before it opens.
            let helper = coordinator.capabilities.ffmpeg.map { FFmpeg(executable: $0) }
            Task {
                let fields = await loader(item.url, helper)
                let model = MetadataModel(allowsArtwork: true, loader: { _ in fields })
                model.load(item.url)
                presentMetadata(model, item: item, action: action, coordinator: coordinator)
            }
        default:
            coordinator.showError(notBuilt)
        }
    }

    private static func presentMetadata(_ model: MetadataModel, item: DroppedItem, action: SliceAction,
                                        coordinator: JobCoordinator) {
        EditorWindowController.present(width: MetadataEditor.width, content: { close, _ in
            MetadataEditor(title: "Metadata", model: model, onClose: close, onApply: { edits in
                let request = JobRequest(items: [item], action: action, parameters: .metadata(edits),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            }, onRemoveLocation: {
                let request = JobRequest(items: [item], action: .tool(.metadata, .metadataStripLocation),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
    }

    // MARK: Media editors

    /// What a media editor needs from the app, so the live check can open one without a coordinator: how to make the
    /// session (the check swaps the preview-proxy maker), the job options, and where the request goes.
    @MainActor
    struct MediaHost {
        var ffmpeg: FFmpeg?
        var options: () -> JobOptions
        var submit: (JobRequest) -> Void
        var makeSession: (DroppedItem) -> MediaSession

        init(ffmpeg: FFmpeg?, options: @escaping () -> JobOptions, submit: @escaping (JobRequest) -> Void,
             makeSession: ((DroppedItem) -> MediaSession)? = nil) {
            self.ffmpeg = ffmpeg
            self.options = options
            self.submit = submit
            self.makeSession = makeSession ?? { MediaSession(item: $0, ffmpeg: ffmpeg) }
        }
    }

    private static func mediaHost(_ coordinator: JobCoordinator) -> MediaHost {
        MediaHost(ffmpeg: coordinator.capabilities.ffmpeg.map { FFmpeg(executable: $0) },
                  options: { coordinator.settings.jobOptions },
                  submit: { coordinator.run($0, near: NSEvent.mouseLocation) })
    }

    /// The file a media editor opens for: the first of the wanted kinds dropped (the slice only appears for one file).
    private static func mediaItem(in items: [DroppedItem], _ categories: Set<FileCategory>) -> DroppedItem? {
        items.first { categories.contains($0.category) }
    }

    private static func openMedia(_ items: [DroppedItem], mode: MediaEditMode, action: SliceAction, coordinator: JobCoordinator) {
        if openMediaRange(items, mode: mode, action: action, host: mediaHost(coordinator)) == nil {
            coordinator.showError(notBuilt)
        }
    }

    /// Trim, Split, Snapshot and Bleep. `onClose` stops the player however the panel closes. Nil when `items` holds
    /// nothing this editor can open.
    @discardableResult
    static func openMediaRange(_ items: [DroppedItem], mode: MediaEditMode, action: SliceAction, host: MediaHost) -> EditorWindowController? {
        let wanted: Set<FileCategory> = switch mode {
        case .trim, .split: [.video, .audio]
        case .snapshot: [.video]
        case .bleep: [.audio]
        }
        guard let item = mediaItem(in: items, wanted) else { return nil }
        let session = host.makeSession(item)
        let model = MediaRangeModel(session: session, mode: mode)
        let title = model.title(for: item.category == .audio ? "Audio" : "Video")
        let controller = EditorWindowController.present(width: MediaRangeEditor.width, onClose: { session.stop() }, content: { close, _ in
            MediaRangeEditor(title: title, model: model, onClose: close, onApply: { parameters in
                host.submit(JobRequest(items: [item], action: action, parameters: parameters, options: host.options()))
                close()
            })
        })
        Task { await model.load() }
        return controller
    }

    @discardableResult
    static func openVideoCrop(_ items: [DroppedItem], action: SliceAction, host: MediaHost) -> EditorWindowController? {
        guard let item = mediaItem(in: items, [.video]) else { return nil }
        let session = host.makeSession(item)
        let model = CropModel(session: session)
        let controller = EditorWindowController.present(width: VideoCropEditor.width, onClose: { session.stop() }, content: { close, _ in
            VideoCropEditor(title: "Crop Video", model: model, onClose: close, onApply: { parameters in
                host.submit(JobRequest(items: [item], action: action, parameters: parameters, options: host.options()))
                close()
            })
        })
        Task { await model.load() }
        return controller
    }

    private static func openCompressCustom(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard !items.isEmpty else { return coordinator.showError(notBuilt) }
        let model = CompressCustomModel()
        model.load(items.map(\.url))
        EditorWindowController.present(width: CompressCustomPanel.width, content: { close, _ in
            CompressCustomPanel(title: "Compress", model: model, onClose: close, onApply: { jobs in
                for request in compressRequests(jobs, items: items, action: action, options: coordinator.settings.jobOptions) {
                    coordinator.run(request, near: NSEvent.mouseLocation)
                }
                close()
            })
        })
    }

    /// One request per planned job: in Percent mode each file has its own target, so a batch is never fitted to
    /// the first file's size.
    static func compressRequests(_ jobs: [CompressPlan.Job], items: [DroppedItem], action: SliceAction,
                                 options: JobOptions) -> [JobRequest] {
        jobs.map { job in
            JobRequest(items: job.indices.map { items[$0] }, action: action, parameters: .compress(job.target),
                       options: options)
        }
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
