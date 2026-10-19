import Foundation

/// Video conversion (to another video format, a GIF, or an audio track). Video tools come later.
public struct VideoProcessor: Processor {
    private static let outputs = Set(ConversionMatrix.table(for: .video))

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .video }) else { return false }
        switch request.action {
        case .convert(let format): return Self.outputs.contains(format)
        case .tool, .action: return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        switch request.action {
        case .convert(let format): return try await convert(request.items, to: format, context: context)
        case .tool, .action: throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    private func convert(_ items: [DroppedItem], to format: OutputFormat, context: JobContext) async throws -> ProcessorOutput {
        var outputs: [URL] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            // The helper check happens before a name is reserved, so a missing ffmpeg leaves nothing behind.
            if !VideoConverter.usesNativePath(item, to: format), context.capabilities.ffmpeg == nil {
                throw OrbitError.helperMissing(.ffmpeg)
            }
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            let ffmpeg = context.capabilities.ffmpeg.map(FFmpeg.init(executable:))
            let count = Double(items.count), base = Double(index)
            try await VideoConverter.convert(item, to: format, output: output, ffmpeg: ffmpeg,
                                             progress: { context.progress((base + $0) / count) })
            outputs.append(output)
        }
        context.progress(1)
        return ProcessorOutput(outputs: outputs)
    }
}
