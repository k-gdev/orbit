import CoreGraphics
import Foundation

/// Encoder settings a job reads from Settings.
public struct JobOptions: Sendable, Equatable {
    public var jpegQuality: Double
    public var heicQuality: Double
    public var webpQuality: Double
    public var avifQuality: Double
    public var pdfDPI: Int

    public init(jpegQuality: Double = 0.85, heicQuality: Double = 0.8, webpQuality: Double = 0.8,
                avifQuality: Double = 0.7, pdfDPI: Int = 300) {
        self.jpegQuality = jpegQuality
        self.heicQuality = heicQuality
        self.webpQuality = webpQuality
        self.avifQuality = avifQuality
        self.pdfDPI = pdfDPI
    }
}

extension SettingsStore {
    public var jobOptions: JobOptions {
        JobOptions(jpegQuality: jpegQuality, heicQuality: heicQuality, webpQuality: webpQuality,
                   avifQuality: avifQuality, pdfDPI: pdfDPI)
    }
}

/// A drop on a slice: the files, what to do with them, and any editor input.
public struct JobRequest: Sendable {
    public var items: [DroppedItem]
    public var action: SliceAction
    public var parameters: ToolParameters
    public var options: JobOptions

    public init(items: [DroppedItem], action: SliceAction, parameters: ToolParameters = .none,
                options: JobOptions = JobOptions()) {
        self.items = items
        self.action = action
        self.parameters = parameters
        self.options = options
    }
}

/// What `JobRunner` gives a processor for one unit of work.
///
/// Every URL the output closures hand out is reserved: it is unique against files on disk and
/// against every other reservation not yet written (in this job and in any job running at the
/// same time), and it is registered for cleanup if the unit fails or the job is cancelled.
public struct JobContext: Sendable {
    public let options: JobOptions
    public let capabilities: Capabilities
    /// This unit's progress, 0...1.
    public let progress: @Sendable (Double) -> Void
    /// `<stem>-<suffix>.<ext>` in the output folder.
    public let outputURL: @Sendable (_ source: URL, _ suffix: String, _ ext: String) -> URL
    /// `<stem>-<suffix>-1.<ext>` … `<stem>-<suffix>-<count>.<ext>` in the output folder.
    public let numberedOutputURLs: @Sendable (_ source: URL, _ suffix: String, _ ext: String, _ count: Int) -> [URL]
    /// `(base ?? stem(first))[-suffix].<ext>` in the output folder; an empty `ext` names a folder.
    public let combinedOutputURL: @Sendable (_ first: URL, _ base: String?, _ suffix: String, _ ext: String) -> URL
    /// A new empty scratch folder, deleted (not trashed) when the unit ends. Outputs must not live
    /// here, and nothing the user owns may be moved into it; copy instead.
    public let tempDirectory: @Sendable () throws -> URL

    public init(options: JobOptions, capabilities: Capabilities,
                progress: @escaping @Sendable (Double) -> Void,
                outputURL: @escaping @Sendable (_ source: URL, _ suffix: String, _ ext: String) -> URL,
                numberedOutputURLs: @escaping @Sendable (_ source: URL, _ suffix: String, _ ext: String, _ count: Int) -> [URL],
                combinedOutputURL: @escaping @Sendable (_ first: URL, _ base: String?, _ suffix: String, _ ext: String) -> URL,
                tempDirectory: @escaping @Sendable () throws -> URL) {
        self.options = options
        self.capabilities = capabilities
        self.progress = progress
        self.outputURL = outputURL
        self.numberedOutputURLs = numberedOutputURLs
        self.combinedOutputURL = combinedOutputURL
        self.tempDirectory = tempDirectory
    }
}

public protocol Processor: Sendable {
    /// Whether this processor handles the request (one unit: a single item, or all items for a combining action).
    func canHandle(_ request: JobRequest) -> Bool
    func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput
}

public struct ProcessorOutput: Sendable {
    public var outputs: [URL]
    public var hint: SummaryHint?
    public var clipboardText: String?
    public var undo: UndoRecord?

    public init(outputs: [URL] = [], hint: SummaryHint? = nil, clipboardText: String? = nil, undo: UndoRecord? = nil) {
        self.outputs = outputs
        self.hint = hint
        self.clipboardText = clipboardText
        self.undo = undo
    }
}

/// What a processor says changed, for the result toast (see `ResultSummary`).
public enum SummaryHint: Equatable, Sendable {
    case sizes(before: Int64, after: Int64)
    case dimensions(from: CGSize, to: CGSize)
    /// `noun` is singular; it gets an "s" when the count isn't 1.
    case count(Int, noun: String)
    case text(String)
}

public struct JobProgress: Equatable, Sendable {
    public var title: String
    public var fileName: String
    /// 0-based index of the current unit.
    public var itemIndex: Int
    /// Number of units in the job (1 for a combining action).
    public var itemCount: Int
    /// Whole-job progress, 0...1, never decreasing.
    public var fraction: Double

    public init(title: String, fileName: String, itemIndex: Int, itemCount: Int, fraction: Double) {
        self.title = title
        self.fileName = fileName
        self.itemIndex = itemIndex
        self.itemCount = itemCount
        self.fraction = fraction
    }
}

public struct JobFailure: Equatable, Sendable {
    public var url: URL
    public var message: String

    public init(url: URL, message: String) {
        self.url = url
        self.message = message
    }
}

public struct JobResult: Equatable, Sendable {
    public var outputs: [URL]
    public var summary: String
    public var undo: UndoRecord?
    public var usedFallbackFolder: Bool
    public var clipboardText: String?
    public var failures: [JobFailure]

    public init(outputs: [URL], summary: String, undo: UndoRecord?, usedFallbackFolder: Bool,
                clipboardText: String?, failures: [JobFailure]) {
        self.outputs = outputs
        self.summary = summary
        self.undo = undo
        self.usedFallbackFolder = usedFallbackFolder
        self.clipboardText = clipboardText
        self.failures = failures
    }
}
