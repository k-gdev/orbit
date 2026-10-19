import Foundation

/// Video conversion (to another video format, a GIF, or an audio track) and the video tools (compress,
/// trim, crop, speed, split, snapshot, mute, remove metadata, join).
public struct VideoProcessor: Processor {
    private static let outputs = Set(ConversionMatrix.table(for: .video))
    private static let tools: Set<ToolID> = [.compress, .trim, .crop, .speed, .split, .snapshot, .mute, .removeMetadata, .join, .metadata]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .video }) else { return false }
        switch request.action {
        case .convert(let format): return Self.outputs.contains(format)
        // Mixed selections hand over "Strip all" as the metadata tool; it is Remove Meta here.
        case .tool(.metadata, let preset): return preset == .metadataStripAll
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

    // MARK: Tools

    /// Native when AVFoundation can read the file and write its container; otherwise ffmpeg.
    static func usesNativePath(_ item: DroppedItem) -> Bool {
        !MediaSupport.needsFFmpegToRead(item) && MediaSupport.isNativelyWritable(formatKey: item.formatKey)
    }

    private func runTool(_ tool: ToolID, preset: Preset?, request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        let suffix = request.action.outputSuffix
        let ffmpeg = context.capabilities.ffmpeg.map(FFmpeg.init(executable:))
        // The helper check happens before any name is reserved, so a missing ffmpeg leaves nothing behind.
        if ffmpeg == nil, request.items.contains(where: { !Self.usesNativePath($0) }) {
            throw OrbitError.helperMissing(.ffmpeg)
        }

        if tool == .join { return try await join(request.items, suffix: suffix, ffmpeg: ffmpeg, context: context) }

        var outputs: [URL] = []
        var hint: SummaryHint?
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let count = Double(request.items.count), base = Double(index)
            let progress: @Sendable (Double) -> Void = { context.progress((base + $0) / count) }
            let native = Self.usesNativePath(item)
            let src = item.url
            let ext = Self.containerExtension(of: item)

            switch tool {
            case .trim:
                guard case .timeRange(let range) = request.parameters else { throw OrbitError.unsupported("Choose the part to keep first.") }
                let out = context.outputURL(src, suffix, ext)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.trim(src, range: range, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.trim(src, range: range, to: out, progress: progress)
                }
                outputs.append(out)
            case .crop:
                guard case .cropRect(let rect) = request.parameters else { throw OrbitError.unsupported("Choose the area to keep first.") }
                let out = context.outputURL(src, suffix, ext)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.crop(src, rect: rect, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.crop(src, rect: rect, to: out, progress: progress)
                }
                outputs.append(out)
            case .speed:
                guard case .speed(let factor)? = preset, factor.isFinite, factor > 0 else {
                    throw OrbitError.unsupported("Choose a speed first.")
                }
                let out = context.outputURL(src, suffix, ext)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.speed(src, factor: factor, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.speed(src, factor: factor, to: out, progress: progress)
                }
                outputs.append(out)
            case .split:
                guard case .splitPoints(let points) = request.parameters, !points.isEmpty else {
                    throw OrbitError.unsupported("Choose where to split first.")
                }
                let parts = context.numberedOutputURLs(src, suffix, ext, points.count + 1)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.split(src, at: points, to: parts, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.split(src, at: points, to: parts, progress: progress)
                }
                outputs += parts
                if request.items.count == 1 { hint = .count(parts.count, noun: "part") }
            case .snapshot:
                guard case .time(let time) = request.parameters else { throw OrbitError.unsupported("Choose a moment first.") }
                let out = context.outputURL(src, suffix, "png")
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.snapshot(src, at: time, to: out, ffmpeg: ffmpeg)
                } else {
                    try await VideoTools.snapshot(src, at: time, to: out)
                }
                outputs.append(out)
            case .mute:
                let out = context.outputURL(src, suffix, ext)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.mute(src, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.mute(src, to: out, progress: progress)
                }
                outputs.append(out)
            case .removeMetadata, .metadata:
                let out = context.outputURL(src, suffix, ext)
                if let ffmpeg, !native {
                    try await VideoToolsFFmpeg.removeMetadata(src, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    try await VideoTools.removeMetadata(src, to: out, progress: progress)
                }
                outputs.append(out)
            case .compress:
                let target = try Self.compressTarget(preset: preset, parameters: request.parameters)
                let out = context.outputURL(src, suffix, ext)
                let after: Int64
                if let ffmpeg, !native {
                    after = try await VideoToolsFFmpeg.compress(src, target: target, to: out, ffmpeg: ffmpeg, progress: progress)
                } else {
                    after = try await VideoTools.compress(src, target: target, to: out, progress: progress)
                }
                outputs.append(out)
                hint = .sizes(before: VideoTools.fileSize(src), after: after)
            default:
                throw OrbitError.unsupported("Orbit can't do that with this file.")
            }
            progress(1)
        }
        context.progress(1)
        return ProcessorOutput(outputs: outputs, hint: request.items.count == 1 ? hint : nil)
    }

    private func join(_ items: [DroppedItem], suffix: String, ffmpeg: FFmpeg?, context: JobContext) async throws -> ProcessorOutput {
        guard let first = items.first, items.count > 1 else { throw OrbitError.unsupported("Choose at least two videos to join.") }
        let out = context.combinedOutputURL(first.url, nil, suffix, Self.containerExtension(of: first))
        let urls = items.map(\.url)
        if let ffmpeg, !items.allSatisfy(Self.usesNativePath) {
            try await VideoToolsFFmpeg.join(urls, to: out, ffmpeg: ffmpeg, scratch: context.tempDirectory,
                                            progress: context.progress)
        } else {
            try await VideoTools.join(urls, to: out, progress: context.progress)
        }
        context.progress(1)
        return ProcessorOutput(outputs: [out])
    }

    /// The extension of the result: the source's own container.
    private static func containerExtension(of item: DroppedItem) -> String {
        item.formatKey.isEmpty ? item.url.pathExtension.lowercased() : item.formatKey
    }

    /// A tier or size from the wheel (a preset) or the custom-size editor (a parameter).
    private static func compressTarget(preset: Preset?, parameters: ToolParameters) throws -> CompressTarget {
        if case .compress(let target)? = preset { return target }
        if case .compress(let target) = parameters { return target }
        throw OrbitError.unsupported("Choose how small to make this video.")
    }
}
