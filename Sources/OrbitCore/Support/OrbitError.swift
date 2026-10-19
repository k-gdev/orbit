import Foundation

public enum OrbitError: Error, Equatable, LocalizedError {
    case helperMissing(Helper)
    case unsupported(String)
    case processFailed(tool: String, code: Int32, stderr: String)
    case cancelled
    case noSubject
    case targetTooSmall(String)

    /// `processFailed` compares `tool` and `code` only; stderr is diagnostic text.
    public static func == (lhs: OrbitError, rhs: OrbitError) -> Bool {
        switch (lhs, rhs) {
        case let (.helperMissing(a), .helperMissing(b)): a == b
        case let (.unsupported(a), .unsupported(b)): a == b
        case let (.processFailed(t1, c1, _), .processFailed(t2, c2, _)): t1 == t2 && c1 == c2
        case (.cancelled, .cancelled), (.noSubject, .noSubject): true
        case let (.targetTooSmall(a), .targetTooSmall(b)): a == b
        default: false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .helperMissing(let h): "Install \(h.displayName) to do this (\(h.installHint))."
        case .unsupported(let m): m
        case .processFailed(let tool, _, _): "\(tool) failed. See the log for details."
        case .cancelled: "Cancelled."
        case .noSubject: "Couldn't find a subject in this image."
        case .targetTooSmall(let m): m
        }
    }
}
