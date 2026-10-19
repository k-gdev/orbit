import Foundation

/// Converts XLSX, XLS, NUMBERS, ODS, CSV and TSV to XLSX, CSV, TSV, ODS, PDF and NUMBERS.
///
/// CSV, TSV and ODS are read, and CSV, TSV, ODS and XLSX (from CSV, TSV or ODS) are written, in Swift.
/// Numbers is needed to read XLSX, XLS and NUMBERS, to write PDF and NUMBERS, and to write XLSX from XLS or NUMBERS.
public struct SpreadsheetProcessor: Processor {
    private static let outputs: Set<OutputFormat> = [.xlsx, .csv, .tsv, .pdf, .numbers, .ods]
    /// Sources Numbers opens itself.
    private static let numbersNative: Set<String> = ["xlsx", "xls", "numbers"]

    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, request.items.allSatisfy({ $0.category == .spreadsheet }),
              case .convert(let format) = request.action else { return false }
        return Self.outputs.contains(format)
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        guard case .convert(let format) = request.action, Self.outputs.contains(format) else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        if request.items.contains(where: { Self.needsNumbers($0, writing: format) }), !context.capabilities.has(.numbers) {
            throw OrbitError.helperMissing(.numbers)
        }
        let bridge = IWorkBridge(capabilities: context.capabilities)
        var outputs: [URL] = []
        for (index, item) in request.items.enumerated() {
            try Task.checkCancellation()
            let output = context.outputURL(item.url, "converted", format.fileExtension)
            try await convert(item, to: format, output: output, bridge: bridge, context: context)
            outputs.append(output)
            context.progress(Double(index + 1) / Double(request.items.count))
        }
        return ProcessorOutput(outputs: outputs)
    }

    private static func needsNumbers(_ item: DroppedItem, writing format: OutputFormat) -> Bool {
        format == .pdf || format == .numbers || numbersNative.contains(item.formatKey)
    }

    // MARK: Conversion

    private func convert(_ item: DroppedItem, to format: OutputFormat, output: URL,
                         bridge: IWorkBridge, context: JobContext) async throws {
        let key = item.formatKey
        switch format {
        case .pdf, .numbers:
            // Numbers opens XLSX, XLS and NUMBERS as they are; anything else goes in as a temporary XLSX
            // that Orbit wrote from the rows, so Numbers never has to guess a delimiter or an encoding.
            var input = item.url
            if !Self.numbersNative.contains(key) {
                let rows = try await readRows(item, bridge: bridge, context: context)
                input = try context.tempDirectory().appending(path: "sheet.xlsx", directoryHint: .notDirectory)
                try await XLSXWriter.write(rows: rows, sheetName: Self.sheetName(item), to: input)
            }
            try await bridge.export(input, app: .numbers, format: format == .pdf ? .pdf : .numbers, to: output)
        case .xlsx where key == "xls" || key == "numbers":
            try await bridge.export(item.url, app: .numbers, format: .excel, to: output)
        case .xlsx:
            try await XLSXWriter.write(rows: try await readRows(item, bridge: bridge, context: context),
                                       sheetName: Self.sheetName(item), to: output)
        case .ods:
            try await ODSWriter.write(rows: try await readRows(item, bridge: bridge, context: context),
                                      sheetName: Self.sheetName(item), to: output)
        case .csv, .tsv:
            let rows = try await readRows(item, bridge: bridge, context: context)
            let text = DelimitedText.write(rows, delimiter: format == .csv ? "," : "\t")
            try Data(text.utf8).write(to: output, options: .withoutOverwriting)
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    private static func sheetName(_ item: DroppedItem) -> String {
        item.url.deletingPathExtension().lastPathComponent
    }

    // MARK: Reading

    private func readRows(_ item: DroppedItem, bridge: IWorkBridge, context: JobContext) async throws -> [[String]] {
        switch item.formatKey {
        case "csv", "tsv":
            let text = TextDecoder.string(from: try Data(contentsOf: item.url))
            return DelimitedText.parse(text, delimiter: item.formatKey == "csv" ? "," : "\t")
        case "ods":
            return try await ODSReader.read(item.url)
        default:
            // XLSX, XLS and NUMBERS: Numbers exports the first sheet as CSV into a scratch folder.
            let folder = try context.tempDirectory().appending(path: "export", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try await bridge.export(item.url, app: .numbers, format: .csv,
                                    to: folder.appending(path: "sheet.csv", directoryHint: .notDirectory))
            guard let csv = Self.firstCSV(in: folder) else { throw OrbitError.unsupported("Numbers didn't export any data.") }
            return DelimitedText.parse(TextDecoder.string(from: try Data(contentsOf: csv)), delimiter: ",")
        }
    }

    /// `url` itself when it is a CSV file; for a folder (Numbers writes one for a document with several
    /// sheets) the first CSV in natural order by file name.
    static func firstCSV(in url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return url.pathExtension.lowercased() == "csv" ? url : nil }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                          options: [.skipsHiddenFiles]) else { return nil }
        var found: [URL] = []
        for case let file as URL in walker where file.pathExtension.lowercased() == "csv" {
            if (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true { found.append(file) }
        }
        return naturalSorted(found).first
    }
}
