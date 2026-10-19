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
            let cues = SubtitleConverter.parse(TextDecoder.string(from: try Data(contentsOf: item.url)), format: input)
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

/// Turns the bytes of a text file into a string without assuming UTF-8.
enum TextDecoder {
    /// UTF-8 (a BOM is dropped), UTF-16 when a BOM says so, otherwise Windows Latin-1.
    static func string(from data: Data) -> String {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]),
           let utf16 = String(data: data, encoding: .utf16) {
            return utf16
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }
}
