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
    /// Size of the file on disk, in bytes; 0 when unknown.
    @Published private(set) var originalBytes: Int64 = 0

    func load(_ url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap { $0 } ?? 0
        set(originalBytes: Int64(size))
    }

    func set(originalBytes: Int64) { self.originalBytes = originalBytes }

    /// What the job gets, or nil when the inputs make no sense (no size to take a percentage of, or an empty size).
    var target: CompressTarget? {
        switch mode {
        case .percent:
            guard originalBytes > 0 else { return nil }
            return .fitUnder(max(1, Int64((Double(originalBytes) * (1 - percent / 100)).rounded())))
        case .size:
            let bytes = (amount * unit.rawValue).rounded()
            return bytes >= 1 && bytes < Double(Int64.max) ? .fitUnder(Int64(bytes)) : nil
        }
    }

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
    let onApply: (CompressTarget) -> Void

    var body: some View {
        EditorShell(title: title, applyTitle: "Compress", canApply: model.target != nil, onClose: onClose,
                    onApply: { if let target = model.target { onApply(target) } }) {
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
            if model.originalBytes > 0 {
                Text("Now \(CompressCustomModel.describe(model.originalBytes))")
            }
            if let bytes = model.targetBytes {
                Text("Aims for under \(CompressCustomModel.describe(bytes))")
            }
        }
        .font(.system(size: 12)).foregroundStyle(.secondary)
    }
}
