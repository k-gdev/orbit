import Combine
import OrbitCore
import SwiftUI

/// State of the Custom compress panel: either a percentage off the current size, or a size to fit under.
@MainActor
final class CompressCustomModel: ObservableObject {
    enum Mode { case percent, size }
    enum Unit: Double, CaseIterable {
        case kilobytes = 1_000, megabytes = 1_000_000
        var title: String { self == .kilobytes ? "KB" : "MB" }
    }

    static let percentRange: ClosedRange<Double> = 10...90

    @Published var mode = Mode.percent
    @Published var percent = 50.0
    @Published var amount = 500.0
    @Published var unit = Unit.kilobytes
    /// Sizes of the files on disk, in bytes, in item order; 0 when unknown.
    @Published private(set) var sizes: [Int64] = []

    func load(_ urls: [URL]) {
        set(sizes: urls.map { url in
            Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0)
        })
    }

    func load(_ url: URL) { load([url]) }

    func set(sizes: [Int64]) { self.sizes = sizes }
    func set(originalBytes: Int64) { set(sizes: [originalBytes]) }

    var fileCount: Int { sizes.count }
    /// Size of the first file; what the summary shows for a single file.
    var originalBytes: Int64 { sizes.first ?? 0 }

    var spec: CompressPlan.Spec? {
        switch mode {
        case .percent:
            return .percentSmaller(percent)
        case .size:
            let bytes = (amount * unit.rawValue).rounded()
            return bytes >= 1 && bytes < Double(Int64.max) ? .underBytes(Int64(bytes)) : nil
        }
    }

    /// The jobs to submit. Percent mode gives one job per file, each with its own target (a percentage is
    /// relative to that file's size); Under size gives one job for all files. Empty when the inputs make no sense.
    var jobs: [CompressPlan.Job] { spec.map { CompressPlan.jobs(for: $0, sizes: sizes) } ?? [] }

    /// The target for the first file, or nil when the inputs make no sense.
    var target: CompressTarget? { spec.flatMap { CompressPlan.target($0, forBytes: originalBytes) } }

    var targetBytes: Int64? {
        if case .fitUnder(let bytes)? = target { return bytes }
        return nil
    }

    static func describe(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct CompressCustomPanel: View {
    static let width: CGFloat = 400

    let title: String
    @ObservedObject var model: CompressCustomModel
    let onClose: () -> Void
    let onApply: ([CompressPlan.Job]) -> Void

    var body: some View {
        EditorShell(title: title, applyTitle: "Compress", canApply: !model.jobs.isEmpty, onClose: onClose,
                    onApply: { let jobs = model.jobs; if !jobs.isEmpty { onApply(jobs) } }) {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    ChoiceChip(title: "Percent smaller", selected: model.mode == .percent) { model.mode = .percent }
                    ChoiceChip(title: "Under size", selected: model.mode == .size) { model.mode = .size }
                    Spacer(minLength: 0)
                }
                switch model.mode {
                case .percent: percentControls
                case .size: sizeControls
                }
                summary
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var percentControls: some View {
        HStack(spacing: 12) {
            OrbitSlider(value: $model.percent, range: CompressCustomModel.percentRange, step: 1)
            Text("\(Int(model.percent))% smaller")
                .font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: 92, alignment: .trailing)
        }
    }

    private var sizeControls: some View {
        HStack(spacing: 10) {
            Text("Smaller than").font(.system(size: 14))
            NumberField(value: $model.amount, width: 80)
            ForEach(CompressCustomModel.Unit.allCases, id: \.self) { unit in
                ChoiceChip(title: unit.title, selected: model.unit == unit) { model.unit = unit }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.fileCount > 1 {
                Text("\(model.fileCount) files, now \(CompressCustomModel.describe(model.sizes.reduce(0, +))) in all")
                switch model.mode {
                case .percent:
                    Text("Each file aims for \(Int(model.percent))% smaller than it is now")
                case .size:
                    if let bytes = model.targetBytes {
                        Text("Each file aims for under \(CompressCustomModel.describe(bytes))")
                    }
                }
            } else {
                if model.originalBytes > 0 {
                    Text("Now \(CompressCustomModel.describe(model.originalBytes))")
                }
                if let bytes = model.targetBytes {
                    Text("Aims for under \(CompressCustomModel.describe(bytes))")
                }
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}
