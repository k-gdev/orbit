import Foundation

/// Turns the Custom compress panel's choice into jobs. A percentage is relative to each file's own size, so
/// it must never be turned into one absolute size for a whole batch; an absolute size applies to every file.
public enum CompressPlan {
    public enum Spec: Equatable, Sendable {
        /// Make each file this many percent smaller than it is now.
        case percentSmaller(Double)
        /// Make each file smaller than this many bytes.
        case underBytes(Int64)
    }

    public struct Job: Equatable, Sendable {
        /// Indices into the sizes passed to `jobs(for:sizes:)`.
        public let indices: [Int]
        public let target: CompressTarget
    }

    /// The target for one file of `bytes`; nil when the spec means nothing for it (unknown size for a percentage,
    /// non-positive size).
    public static func target(_ spec: Spec, forBytes bytes: Int64) -> CompressTarget? {
        switch spec {
        case .percentSmaller(let percent):
            guard bytes > 0 else { return nil }
            return .fitUnder(max(1, Int64((Double(bytes) * (1 - percent / 100)).rounded())))
        case .underBytes(let limit):
            return limit >= 1 ? .fitUnder(limit) : nil
        }
    }

    /// Percent mode: one job per file (each with its own target; files of unknown size are left out).
    /// Under size: a single job holding every file.
    public static func jobs(for spec: Spec, sizes: [Int64]) -> [Job] {
        switch spec {
        case .percentSmaller:
            return sizes.enumerated().compactMap { index, bytes in
                target(spec, forBytes: bytes).map { Job(indices: [index], target: $0) }
            }
        case .underBytes:
            guard !sizes.isEmpty, let target = target(spec, forBytes: 0) else { return [] }
            return [Job(indices: Array(sizes.indices), target: target)]
        }
    }
}
