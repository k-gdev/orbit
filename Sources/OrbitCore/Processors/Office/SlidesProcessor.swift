import Foundation

/// Converts PPTX, PPT and KEY presentations to PDF, PPTX, KEY and one image per slide.
/// Keynote does all of it, so Keynote must be installed.
public struct SlidesProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.pdf, .pptx, .key, .jpg, .png]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .slides }),
              case .convert(let format) = request.action else { return false }
        return Self.outputs.contains(format)
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        guard case .convert(let format) = request.action, Self.outputs.contains(format) else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        guard context.capabilities.has(.keynote) else { throw OrbitError.helperMissing(.keynote) }
        let bridge = IWorkBridge(capabilities: context.capabilities)
        var outputs: [URL] = []
        var slideCount = 0
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            switch format {
            case .jpg, .png:
                let slides = try await slideImages(item, format: format, bridge: bridge, context: context)
                outputs += slides
                slideCount += slides.count
            default:
                let output = context.outputURL(item.url, "converted", format.fileExtension)
                try await bridge.export(item.url, app: .keynote, format: Self.iworkFormat(format), to: output)
                outputs.append(output)
            }
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        let isImages = format == .jpg || format == .png
        return ProcessorOutput(outputs: outputs, hint: isImages ? .count(slideCount, noun: "slide") : nil)
    }

    private static func iworkFormat(_ format: OutputFormat) -> IWorkFormat {
        switch format {
        case .pptx: .powerpoint
        case .key: .keynote
        default: .pdf
        }
    }

    /// Keynote writes the slides into a scratch folder; each image then moves to `<stem>-slide-<n>.<ext>`
    /// in Keynote's order (sorted naturally).
    private func slideImages(_ item: DroppedItem, format: OutputFormat, bridge: IWorkBridge,
                             context: JobContext) async throws -> [URL] {
        let scratch = try context.tempDirectory()
        // Keynote creates the folder; the bridge refuses to export onto something that exists.
        let folder = scratch.appending(path: "slides", directoryHint: .isDirectory)
        try await bridge.export(item.url, app: .keynote, format: .slideImages(format), to: folder)
        let exported = Self.images(in: FileManager.default.fileExists(atPath: folder.path) ? folder : scratch)
        guard !exported.isEmpty else { throw OrbitError.unsupported("Keynote didn't export any slides.") }
        let targets = context.numberedOutputURLs(item.url, "slide", format.fileExtension, exported.count)
        for (image, target) in zip(exported, targets) {
            try FileManager.default.moveItem(at: image, to: target)
        }
        return targets
    }

    /// The PNG and JPEG files under `folder`, in natural order by file name.
    static func images(in folder: URL) -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return [] }
        var found: [URL] = []
        for case let url as URL in walker {
            guard ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased()),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            found.append(url)
        }
        return naturalSorted(found)
    }
}
