import Foundation

/// Copy Path, Copy To and Move To. All three combine every dropped item into one unit (R17-R19).
/// Float, AirDrop and Terminal are app-side and never reach a processor.
public struct ActionProcessor: Processor {
    public init() {}

    public func canHandle(_ request: JobRequest) -> Bool {
        guard !request.items.isEmpty, case .action(let id, let preset) = request.action else { return false }
        switch id {
        case .copyPath:
            if case .pathStyle? = preset { return true }
            return false
        case .copyTo, .moveTo:
            return folder(for: request) != nil
        default:
            return false
        }
    }

    public func run(_ request: JobRequest, context: JobContext) async throws -> ProcessorOutput {
        guard case .action(let id, let preset) = request.action else {
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
        let urls = request.items.map(\.url)
        switch id {
        case .copyPath:
            var style = PathStyle.posix
            if case .pathStyle(let s)? = preset { style = s }
            context.progress(1)
            return ProcessorOutput(hint: .text(urls.count == 1 ? "Copied path" : "Copied \(urls.count) paths"),
                                   clipboardText: FileActions.pathText(urls, style: style))
        case .copyTo:
            let copies = try FileActions.copy(urls, to: try destination(request), name: context.claimDestination,
                                          check: { try Task.checkCancellation() })
            context.progress(1)
            return ProcessorOutput(outputs: copies, hint: .count(copies.count, noun: "file"), undo: .trash(copies))
        case .moveTo:
            let moves = try FileActions.move(urls, to: try destination(request), name: context.claimDestination,
                                          check: { try Task.checkCancellation() })
            context.progress(1)
            return ProcessorOutput(outputs: moves.map(\.to), hint: .count(moves.count, noun: "file"),
                                   undo: .moveBack(moves))
        default:
            throw OrbitError.unsupported("Orbit can't do that with this file.")
        }
    }

    private func folder(for request: JobRequest) -> URL? {
        if case .action(_, .folder(let url)?) = request.action { return url }
        if case .folder(let url) = request.parameters { return url }
        return nil
    }

    private func destination(_ request: JobRequest) throws -> URL {
        guard let url = folder(for: request) else { throw OrbitError.unsupported("Choose a folder first.") }
        return url
    }
}
