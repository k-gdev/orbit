import Foundation

/// Audio conversion and the audio tools (compress, trim, normalize, bleep, channels, metadata).
public struct AudioProcessor: Processor {
    private static let outputs = Set(ConversionMatrix.table(for: .audio))
    private static let tools: Set<ToolID> = [.compress, .trim, .normalize, .bleep, .channels, .metadata]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .audio }) else { return false }
        switch request.action {
        case .convert(let format): return Self.outputs.contains(format)
        case .tool(let tool, _): return Self.tools.contains(tool)
        case .action: return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        switch request.action {
        case .convert(let format): return try await convert(request.items, to: format, context: context)
        case .tool(let tool, let preset): return try await runTool(tool, preset: preset, request: request, context: context)
        case .action: throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    // MARK: Convert

    private func convert(_ items: [DroppedItem], to format: OutputFormat, context: JobContext) async throws -> ProcessorOutput {
        var outputs: [URL] = []
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            // The helper check happens before a name is reserved, so a missing ffmpeg leaves nothing behind.
            if !AudioConverter.usesNativePath(item, to: format), context.capabilities.ffmpeg == nil {
                throw OrbitError.helperMissing(.ffmpeg)
            }
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            let count = Double(items.count), base = Double(index)
            try await AudioConverter.convert(item, to: format, output: output, ffmpeg: Self.ffmpeg(context),
                                             progress: { context.progress((base + $0) / count) })
            outputs.append(output)
        }
        context.progress(1)
        return ProcessorOutput(outputs: outputs)
    }

    // MARK: Tools

    private func runTool(_ tool: ToolID, preset: Preset?, request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        var outputs: [URL] = []
        var hint: SummaryHint?
        let suffix = request.action.outputSuffix
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let count = Double(request.items.count), base = Double(index)
            let progress: @Sendable (Double) -> Void = { context.progress((base + $0) / count) }

            if tool == .metadata {
                outputs.append(try await metadata(item, preset: preset, parameters: request.parameters,
                                                  suffix: suffix, context: context, progress: progress))
                context.progress((base + 1) / count)
                continue
            }

            let op = try Self.operation(for: tool, preset: preset, parameters: request.parameters)
            let format = try AudioTools.outputFormat(for: item, op: op)
            if AudioTools.requiresFFmpeg(item, op: op), context.capabilities.ffmpeg == nil {
                throw OrbitError.helperMissing(.ffmpeg)
            }
            let output = context.outputURL(item.url, suffix, format.fileExtension)
            try await AudioTools.process(item, op: op, output: output, ffmpeg: Self.ffmpeg(context),
                                         scratch: context.tempDirectory, progress: progress)
            outputs.append(output)
            if case .compress = op { hint = Self.sizes(before: item.url, after: output) }
        }
        context.progress(1)
        return ProcessorOutput(outputs: outputs, hint: request.items.count == 1 ? hint : nil)
    }

    private func metadata(_ item: DroppedItem, preset: Preset?, parameters: ToolParameters, suffix: String,
                          context: JobContext, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let ext = item.formatKey.isEmpty ? item.url.pathExtension.lowercased() : item.formatKey
        let ffmpeg = Self.ffmpeg(context)
        let needsFFmpeg = ffmpeg == nil && (preset == .metadataStripAll
            ? !(["m4a", "aac"].contains(item.formatKey) || AudioTools.lossless.contains(item.formatKey))
            : item.formatKey != "m4a")
        if needsFFmpeg { throw OrbitError.helperMissing(.ffmpeg) }

        if preset == .metadataStripAll {
            let output = context.outputURL(item.url, suffix, ext)
            try await AudioMetadata.strip(item, to: output, ffmpeg: ffmpeg)
            return output
        }
        guard case .metadata(let edits) = parameters else {
            throw OrbitError.unsupported("There are no metadata changes to save.")
        }
        let output = context.outputURL(item.url, suffix, ext)
        try await AudioMetadata.edit(item, edits: edits, to: output, ffmpeg: ffmpeg)
        return output
    }

    // MARK: Helpers

    private static func ffmpeg(_ context: JobContext) -> FFmpeg? {
        context.capabilities.ffmpeg.map(FFmpeg.init(executable:))
    }

    private static func operation(for tool: ToolID, preset: Preset?, parameters: ToolParameters) throws -> AudioTools.Operation {
        switch tool {
        case .compress:
            return .compress(try rate(preset: preset, parameters: parameters))
        case .trim:
            guard case .timeRange(let range) = parameters else { throw OrbitError.unsupported("Choose the part to keep first.") }
            return .trim(range)
        case .normalize:
            return .normalize
        case .bleep:
            guard case .bleepRanges(let ranges) = parameters, !ranges.isEmpty else {
                throw OrbitError.unsupported("Mark the parts to bleep first.")
            }
            return .bleep(ranges)
        case .channels:
            guard case .channels(let op)? = preset else { throw OrbitError.unsupported("Choose a channel layout first.") }
            return .channels(op)
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    /// A bitrate preset ("Smaller" is 0), or the target a mixed selection hands over (light 192,
    /// medium 128, strong 96 kbps).
    private static func rate(preset: Preset?, parameters: ToolParameters) throws -> AudioTools.Rate {
        if case .bitrate(let kbps)? = preset { return kbps == 0 ? .smaller : .kbps(kbps) }
        var target: CompressTarget?
        if case .compress(let t)? = preset { target = t }
        if target == nil, case .compress(let t) = parameters { target = t }
        switch target {
        case .tier(let tier)?: return .kbps(AudioTools.kbps(for: tier))
        case .fitUnder(let bytes)?: return .fitUnder(bytes)
        case nil: throw OrbitError.unsupported("Choose how small to make this audio.")
        }
    }

    private static func sizes(before: URL, after: URL) -> SummaryHint? {
        func size(_ url: URL) -> Int64? { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) }
        guard let b = size(before), let a = size(after) else { return nil }
        return .sizes(before: b, after: a)
    }
}
