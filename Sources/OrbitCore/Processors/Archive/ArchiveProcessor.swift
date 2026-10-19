import Foundation

/// Archive actions: pack files into zip/tar/tgz (Convert wheel and Actions > Archive), repack an
/// archive into another format, and extract.
public struct ArchiveProcessor: Processor {
    public init() {}

    private static let packFormats: Set<OutputFormat> = [.zip, .tar, .tgz]

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty else { return false }
        switch request.action {
        case .convert(let format):
            return Self.packFormats.contains(format)
        case .tool(.extract, _):
            return request.items.allSatisfy { $0.category == .archive }
        case .action(.archive, let preset):
            if case .archive(let format)? = preset { return Self.packFormats.contains(format) }
            return preset == nil
        default:
            return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        switch request.action {
        case .tool(.extract, _):
            return try await extract(request.items, context: context)
        case .convert(let format):
            return try await packOrRepack(request.items, format: format, context: context)
        case .action(.archive, let preset):
            if case .archive(let format)? = preset {
                return try await packOrRepack(request.items, format: format, context: context, forcePack: true)
            }
            return try await packOrRepack(request.items, format: .zip, context: context, forcePack: true)
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    // MARK: Pack and repack

    private func packOrRepack(_ items: [DroppedItem], format: OutputFormat, context: JobContext,
                              forcePack: Bool = false) async throws -> ProcessorOutput {
        let ext = format.fileExtension
        if !forcePack, items.allSatisfy({ $0.category == .archive }) {
            var outputs: [URL] = []
            for (index, item) in items.enumerated() {
                try Task.checkCancellation()
                let output = context.combinedOutputURL(item.url, nil, "", ext)
                try await Archiver.repack(item, to: format, output: output, temp: try context.tempDirectory())
                outputs.append(output)
                context.progress(Double(index + 1) / Double(items.count))
            }
            return ProcessorOutput(outputs: outputs)
        }

        let urls = items.map(\.url)
        let output = context.combinedOutputURL(urls[0], urls.count == 1 ? urls[0].lastPathComponent : "Archive", "", ext)
        context.progress(0.1)
        try await Archiver.pack(urls, format: format, to: output, temp: try context.tempDirectory())
        context.progress(1)
        return ProcessorOutput(outputs: [output], hint: .count(urls.count, noun: "item"))
    }

    // MARK: Extract

    private func extract(_ items: [DroppedItem], context: JobContext) async throws -> ProcessorOutput {
        var outputs: [URL] = []
        var total = 0
        for (index, item) in items.enumerated() {
            try Task.checkCancellation()
            let temp = try context.tempDirectory()
            let result = try await Archiver.extract(item, temp: temp) { onlyItem in
                if let onlyItem {
                    let name = onlyItem.lastPathComponent
                    return context.combinedOutputURL(item.url, URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent,
                                                     "", URL(fileURLWithPath: name).pathExtension)
                }
                return context.outputURL(item.url, "", "")
            }
            outputs.append(result.url)
            total += result.count
            context.progress(Double(index + 1) / Double(items.count))
        }
        return ProcessorOutput(outputs: outputs, hint: .count(total, noun: "item"))
    }
}
