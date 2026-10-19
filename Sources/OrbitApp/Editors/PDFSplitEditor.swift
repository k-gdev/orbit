import Combine
import Foundation
import OrbitCore
import PDFKit
import SwiftUI

/// State of the Split editor: the text the person types and what `PageRangeParser` makes of it.
@MainActor
final class SplitModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var pageCount = 0
    @Published private(set) var loadError: String?

    /// The parsed ranges, or nil while the text is empty or invalid.
    var ranges: [ClosedRange<Int>]? { PageRangeParser.parse(text, pageCount: pageCount) }

    /// The text is non-empty but does not parse: the field turns red and says why.
    var isInvalid: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty && ranges == nil }

    func load(_ url: URL) async {
        let count: Int? = await Task.detached(priority: .userInitiated) { PDFDocument(url: url)?.pageCount }.value
        if let count, count > 0 { pageCount = count } else { loadError = "Orbit can't read this PDF." }
    }

    /// Supplies the page count directly (headless snapshots).
    func set(pageCount: Int) { self.pageCount = pageCount }

    /// "Page 5" or "Pages 1–3".
    static func chipTitle(_ range: ClosedRange<Int>) -> String {
        range.count == 1 ? "Page \(range.lowerBound)" : "Pages \(range.lowerBound)–\(range.upperBound)"
    }
}

struct PDFSplitEditor: View {
    static let width: CGFloat = 420

    let title: String
    @ObservedObject var model: SplitModel
    let onClose: () -> Void
    let onApply: ([ClosedRange<Int>]) -> Void

    var body: some View {
        EditorShell(title: title, applyTitle: "Split", canApply: model.ranges != nil, onClose: onClose,
                    onApply: { if let ranges = model.ranges { onApply(ranges) } }) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Pages to split out")
                    .font(.system(size: 14, weight: .medium))
                EditorTextField(placeholder: "1-3, 5", text: $model.text, invalid: model.isInvalid, autofocus: true)
                status
                chips
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var status: some View {
        if let error = model.loadError {
            Text(error).font(.system(size: 12)).foregroundStyle(.red)
        } else if model.isInvalid {
            Text("Use page numbers from 1 to \(model.pageCount), like 1-3, 5.")
                .font(.system(size: 12)).foregroundStyle(.red)
        } else if model.pageCount > 0 {
            Text("This PDF has \(model.pageCount) \(model.pageCount == 1 ? "page" : "pages"). Separate ranges with commas.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var chips: some View {
        if let ranges = model.ranges {
            ChipFlow(spacing: 6) {
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                    Text(SplitModel.chipTitle(range))
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(EditorStyle.accent))
                }
            }
        }
    }
}

// MARK: Shared small controls

/// A single-line text field (live), or a plain box with the text (snapshots, which cannot draw a `TextField`).
/// The other utility editors use it too.
struct EditorTextField: View {
    let placeholder: String
    @Binding var text: String
    var invalid = false
    var autofocus = false

    @Environment(\.glassRendering) private var rendering
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if rendering == .live {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onAppear { if autofocus { focused = true } }
            } else {
                Text(text.isEmpty ? placeholder : text)
                    .foregroundStyle(text.isEmpty ? Color.secondary : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 13))
        .lineLimit(1)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.red.opacity(invalid ? 0.8 : 0), lineWidth: 1.5))
    }
}

/// Lays its children out left to right, wrapping to a new line when a row is full.
struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, layout.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (origins: [CGPoint], size: CGSize) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (origins, CGSize(width: widest, height: y + rowHeight))
    }
}
