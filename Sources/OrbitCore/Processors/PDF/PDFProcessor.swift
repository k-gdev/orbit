import Foundation
import PDFKit

/// PDF conversion (images, text, Markdown, Word, EPUB, PowerPoint, Excel, Pages) and the PDF tools
/// (compress, merge, split, organize, redact, remove metadata).
public struct PDFProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.jpg, .png, .txt, .md, .docx, .epub, .pptx, .xlsx, .pages]
    private static let tools: Set<ToolID> = [.compress, .merge, .split, .organize, .redact, .metadata]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .pdf }) else { return false }
        switch request.action {
        case .convert(let format):
            return Self.outputs.contains(format)
        case .tool(.metadata, let preset):
            return preset == .metadataStripAll
        case .tool(let tool, _):
            return Self.tools.contains(tool)
        case .action:
            return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        switch request.action {
        case .convert(let format):
            return try await convert(request.items, to: format, context: context)
        case .tool(.merge, _):
            return try merge(request.items, context: context)
        case .tool(let tool, let preset):
            return try runTools(tool, preset: preset, request: request, context: context)
        case .action:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    // MARK: Convert

    private func convert(_ items: [DroppedItem], to format: OutputFormat, context: JobContext) async throws -> ProcessorOutput {
        var outputs: [URL] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let src = item.url
            switch format {
            case .jpg, .png:
                let pages = try PDFRender.open(src).pageCount
                let urls = context.numberedOutputURLs(src, "page", format.fileExtension, pages)
                try PDFConverter.images(src, format: format, dpi: context.options.pdfDPI,
                                        quality: context.options.jpegQuality, to: urls)
                outputs += urls
            default:
                let output = context.outputURL(src, "converted", format.fileExtension)
                try await write(src, as: format, to: output, context: context)
                outputs.append(output)
            }
            context.progress(Double(index + 1) / Double(items.count))
        }
        return ProcessorOutput(outputs: outputs)
    }

    private func write(_ src: URL, as format: OutputFormat, to output: URL, context: JobContext) async throws {
        switch format {
        case .txt:
            try Data(try PDFConverter.text(src).utf8).write(to: output, options: .withoutOverwriting)
        case .md:
            try Data(try PDFConverter.markdown(src).utf8).write(to: output, options: .withoutOverwriting)
        case .docx:
            try PDFConverter.docx(src, to: output)
        case .epub:
            try await PDFConverter.epub(src, to: output)
        case .pptx:
            try await PDFConverter.pptx(src, to: output)
        case .xlsx:
            try await PDFConverter.xlsx(src, to: output)
        case .pages:
            guard context.capabilities.has(.pages) else { throw OrbitError.helperMissing(.pages) }
            // Pages opens a temporary Word document and saves it as a Pages file.
            let fm = FileManager.default
            let scratch = fm.temporaryDirectory.appending(path: "orbit-docx-\(UUID().uuidString)", directoryHint: .isDirectory)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: scratch) }
            let docx = scratch.appending(path: "document.docx", directoryHint: .notDirectory)
            try PDFConverter.docx(src, to: docx)
            try await IWorkBridge(capabilities: context.capabilities).export(docx, app: .pages, format: .pages, to: output)
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    // MARK: Tools

    private func merge(_ items: [DroppedItem], context: JobContext) throws -> ProcessorOutput {
        let output = context.combinedOutputURL(items[0].url, nil, "merged", "pdf")
        let pages = try PDFTools.merge(items.map(\.url), to: output)
        context.progress(1)
        return ProcessorOutput(outputs: [output], hint: .count(pages, noun: "page"))
    }

    private func runTools(_ tool: ToolID, preset: Preset?, request: JobRequest, context: JobContext) throws -> ProcessorOutput {
        var outputs: [URL] = []
        var hint: SummaryHint?
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let src = item.url
            switch tool {
            case .compress:
                let target = try Self.compressTarget(preset: preset, parameters: request.parameters)
                let output = context.outputURL(src, "compressed", "pdf")
                let after = try PDFTools.compress(src, target: target, to: output)
                hint = .sizes(before: try Self.size(of: src), after: after)
                outputs.append(output)
            case .split:
                let ranges = try Self.splitRanges(preset: preset, parameters: request.parameters, source: src)
                let urls = context.numberedOutputURLs(src, "part", "pdf", ranges.count)
                try PDFTools.split(src, ranges: ranges, outputs: urls)
                outputs += urls
            case .organize:
                guard case .pdfPages(let pages) = request.parameters else {
                    throw OrbitError.unsupported("Arrange the pages first.")
                }
                let output = context.outputURL(src, "organized", "pdf")
                try PDFTools.organize(src, pages: pages, to: output)
                outputs.append(output)
            case .redact:
                guard case .pdfRedactions(let redactions) = request.parameters else {
                    throw OrbitError.unsupported("Mark what to redact first.")
                }
                let output = context.outputURL(src, "redacted", "pdf")
                try PDFTools.redact(src, redactions: redactions, dpi: context.options.pdfDPI, to: output)
                outputs.append(output)
            case .metadata:
                guard preset == .metadataStripAll else {
                    throw OrbitError.unsupported("Orbit can only remove the metadata from a PDF.")
                }
                let output = context.outputURL(src, "clean", "pdf")
                try PDFTools.stripMetadata(src, to: output)
                outputs.append(output)
            default:
                throw OrbitError.unsupported("Orbit can't do that with this file.")
            }
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        return ProcessorOutput(outputs: outputs, hint: request.items.count == 1 ? hint : nil)
    }

    private static func compressTarget(preset: Preset?, parameters: ToolParameters) throws -> CompressTarget {
        if case .compress(let target)? = preset { return target }
        if case .compress(let target) = parameters { return target }
        throw OrbitError.unsupported("Choose how small to make this PDF.")
    }

    private static func splitRanges(preset: Preset?, parameters: ToolParameters, source: URL) throws -> [ClosedRange<Int>] {
        if preset == .pdfSplitEveryPage {
            let count = try PDFRender.open(source).pageCount
            return (1...count).map { $0...$0 }
        }
        if case .pdfRanges(let ranges) = parameters { return ranges }
        throw OrbitError.unsupported("Choose the pages to split out.")
    }

    private static func size(of url: URL) throws -> Int64 {
        Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
    }
}
