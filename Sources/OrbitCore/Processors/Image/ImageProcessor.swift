import Foundation

/// Image format conversion, and several images into one PDF.
public struct ImageProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.jpg, .png, .heic, .webp, .tiff, .avif, .bmp, .gif, .ico, .pdf]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard case .convert(let format) = request.action, Self.outputs.contains(format) else { return false }
        return !request.items.isEmpty && request.items.allSatisfy { $0.category == .image }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
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
}
