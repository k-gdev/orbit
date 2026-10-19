import AppKit
import OrbitCore

/// Opens the editor a slice asks for. Choose…, the image editors (Markup, Adjust, Add BG) and the document and
/// utility editors (Redact, Organize, Split, Metadata, Custom compress) exist so far; Task 27 adds the media editors.
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
        default:
            coordinator.showError(notBuilt)
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

    /// Reads audio tags for the Metadata editor. `AudioMetadata` (Task 19) is not in this build yet; when it lands, set this to
    /// `{ AudioMetadata.read($0) }` and audio files get their editor. Until then audio is refused with a plain message.
    static var audioMetadataLoader: MetadataLoader?

    private static func openMetadata(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = items.first else { return coordinator.showError(notBuilt) }
        let model: MetadataModel
        switch item.category {
        case .image:
            model = MetadataModel(allowsArtwork: false, loader: { ImageMetadata.read($0) })
        case .audio:
            guard let loader = audioMetadataLoader else {
                return coordinator.showError("Editing audio metadata isn't available yet.")
            }
            model = MetadataModel(allowsArtwork: true, loader: loader)
        default:
            return coordinator.showError(notBuilt)
        }
        model.load(item.url)
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

    private static func openCompressCustom(_ items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        guard let item = items.first else { return coordinator.showError(notBuilt) }
        let model = CompressCustomModel()
        model.load(item.url)
        EditorWindowController.present(width: CompressCustomPanel.width, content: { close, _ in
            CompressCustomPanel(title: "Compress", model: model, onClose: close, onApply: { target in
                let request = JobRequest(items: items, action: action, parameters: .compress(target),
                                         options: coordinator.settings.jobOptions)
                coordinator.run(request, near: NSEvent.mouseLocation)
                close()
            })
        })
    }

    private final class Box<T> {
        var value: T
        init(_ value: T) { self.value = value }
    }
}
