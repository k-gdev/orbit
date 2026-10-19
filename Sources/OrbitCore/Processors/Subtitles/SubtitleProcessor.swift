import Foundation

/// Converts SRT and WebVTT subtitles to SRT, VTT and plain text. Pure Swift.
public struct SubtitleProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.srt, .vtt, .txt]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .subtitle }),
              case .convert(let format) = request.action else { return false }
        return Self.outputs.contains(format)
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        guard case .convert(let format) = request.action else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        var outputs: [URL] = []
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let input: SubtitleFormat = item.formatKey == "vtt" ? .vtt : .srt
            let cues = SubtitleConverter.parse(TextDecoding.string(from: try Data(contentsOf: item.url)), format: input)
            let text: String
            switch format {
            case .srt: text = SubtitleConverter.srt(cues)
            case .vtt: text = SubtitleConverter.vtt(cues)
            default: text = SubtitleConverter.plainText(cues)
            }
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            try Data(text.utf8).write(to: output, options: .withoutOverwriting)
            outputs.append(output)
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        return ProcessorOutput(outputs: outputs)
    }
}
