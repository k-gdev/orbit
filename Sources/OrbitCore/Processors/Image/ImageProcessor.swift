import Foundation

/// Image format conversion, several images into one PDF, and the one-shot image tools
/// (remove background, compress, metadata, read QR, collage).
public struct ImageProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.jpg, .png, .heic, .webp, .tiff, .avif, .bmp, .gif, .ico, .pdf]

    public init() {}

    private static let tools: Set<ToolID> = [.removeBackground, .compress, .metadata, .readQR, .collage]

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .image }) else { return false }
        switch request.action {
        case .convert(let format): return Self.outputs.contains(format)
        case .tool(let tool, _): return Self.tools.contains(tool)
        case .action: return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        if case .tool(let tool, let preset) = request.action {
            return try runTool(tool, preset: preset, request: request, context: context)
        }
        guard case .convert(let format) = request.action else { throw OrbitError.unsupported("Orbit can't do that with this file.") }

        if format == .pdf, request.items.count > 1 {
            let output = context.combinedOutputURL(request.items[0].url, nil, "combined", "pdf")
            try ImagesToPDF.make(request.items.map(\.url), output: output)
            context.progress(1)
            return ProcessorOutput(outputs: [output], hint: .count(request.items.count, noun: "page"))
        }

        var outputs: [URL] = []
        var hint: SummaryHint?
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            hint = try ImageConverter.convert(item.url, to: format, output: output, options: context.options)
            outputs.append(output)
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        return ProcessorOutput(outputs: outputs, hint: request.items.count == 1 ? hint : nil)
    }

    // MARK: Tools

    private func runTool(_ tool: ToolID, preset: Preset?, request: JobRequest, context: JobContext) throws -> ProcessorOutput {
        switch tool {
        case .readQR: return try readQR(request, context: context)
        case .collage: return try collage(request, context: context)
        default: break
        }
        var outputs: [URL] = []
        var hint: SummaryHint?
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            switch tool {
            case .removeBackground:
                let image = try BackgroundRemover.cutout(item.url)
                let output = context.outputURL(item.url, "nobg", "png")
                try ImageFile.write(image, to: output, format: .png, quality: nil, properties: nil)
                outputs.append(output)
            case .compress:
                let target = try Self.compressTarget(preset: preset, parameters: request.parameters)
                let image = try ImageFile.loadOriented(item.url)
                let format = ImageCompressor.outputFormat(for: item, hasAlpha: ImageFile.hasAlpha(image))
                let output = context.outputURL(item.url, "compressed", format.fileExtension)
                let sizes = try ImageCompressor.compress(item.url, target: target, format: format, to: output,
                                                         options: context.options)
                hint = .sizes(before: sizes.before, after: sizes.after)
                outputs.append(output)
            case .metadata:
                let ext = item.formatKey.isEmpty ? item.url.pathExtension.lowercased() : item.formatKey
                switch preset {
                case .metadataStripAll?, .metadataStripLocation?:
                    let output = context.outputURL(item.url, "clean", ext)
                    try ImageMetadata.strip(item.url, to: output, locationOnly: preset == .metadataStripLocation)
                    outputs.append(output)
                default:
                    guard case .metadata(let edits) = request.parameters else {
                        throw OrbitError.unsupported("There are no metadata changes to save.")
                    }
                    let output = context.outputURL(item.url, "edited", ext)
                    try ImageMetadata.write(item.url, to: output, edits: edits)
                    outputs.append(output)
                }
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
        throw OrbitError.unsupported("Choose how small to make this image.")
    }

    private func readQR(_ request: JobRequest, context: JobContext) throws -> ProcessorOutput {
        var codes: [String] = []
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            codes += try QRReader.read(item.url)
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        guard let first = codes.first else { throw OrbitError.unsupported("No QR code found.") }
        let hint: SummaryHint = codes.count == 1 ? .text("Copied: \(first.prefix(60))") : .text("Copied \(codes.count) QR codes")
        return ProcessorOutput(hint: hint, clipboardText: codes.joined(separator: "\n"))
    }

    private func collage(_ request: JobRequest, context: JobContext) throws -> ProcessorOutput {
        let urls = request.items.map(\.url)
        let ext = CollageMaker.anyHasAlpha(urls) ? "png" : "jpg"
        let output = context.combinedOutputURL(urls[0], nil, "collage", ext)
        try CollageMaker.make(urls, to: output, quality: context.options.jpegQuality)
        context.progress(1)
        return ProcessorOutput(outputs: [output], hint: .count(urls.count, noun: "image"))
    }
}
