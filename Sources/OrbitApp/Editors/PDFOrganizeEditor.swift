import AppKit
import Combine
import OrbitCore
import PDFKit
import SwiftUI

/// State of the Organize editor: the pages in their new order, each with the quarter turns it gets.
/// A page is identified by its index in the source PDF, which is also what the job needs.
@MainActor
final class OrganizeModel: ObservableObject {
    struct Page: Identifiable, Equatable {
        /// Index in the source PDF (0-based).
        let id: Int
        var quarterTurns = 0
        var thumbnail: NSImage?
    }

    @Published private(set) var pages: [Page] = []
    @Published private(set) var pageCount = 0
    @Published private(set) var loadError: String?
    /// The page being dragged, if any.
    @Published var dragging: Int?

    /// True once the order, the page set or a rotation differs from the source.
    var changed: Bool { pages.map(\.id) != Array(0..<pageCount) || pages.contains { $0.quarterTurns % 4 != 0 } }

    /// The pages for the job, in order. Quarter turns are clockwise, 0...3.
    var operations: [PageOp] { pages.map { PageOp(sourceIndex: $0.id, quarterTurns: (($0.quarterTurns % 4) + 4) % 4) } }

    /// Opens the PDF and makes the thumbnails, a few at a time so the editor stays responsive on long documents.
    func load(_ url: URL) async {
        guard let document = PDFDocument(url: url) else { return fail("Orbit can't read this PDF.") }
        guard !document.isLocked else { return fail("This PDF is password protected. Unlock it first.") }
        guard document.pageCount > 0 else { return fail("This PDF has no pages.") }
        reset(pageCount: document.pageCount)
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let image = page.thumbnail(of: Self.thumbnailSize, for: .cropBox)
            if let position = pages.firstIndex(where: { $0.id == index }) { pages[position].thumbnail = image }
            if index % 4 == 3 { await Task.yield() }
        }
    }

    /// Supplies the pages directly (headless snapshots).
    func set(document: PDFDocument) {
        reset(pageCount: document.pageCount)
        for index in 0..<document.pageCount {
            pages[index].thumbnail = document.page(at: index)?.thumbnail(of: Self.thumbnailSize, for: .cropBox)
        }
    }

    private func fail(_ message: String) { loadError = message }

    static let thumbnailSize = CGSize(width: 200, height: 260)

    private func reset(pageCount: Int) {
        self.pageCount = pageCount
        pages = (0..<pageCount).map { Page(id: $0) }
    }

    /// Back to the source order with nothing removed or rotated.
    func resetAll() {
        let thumbnails = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0.thumbnail) })
        pages = (0..<pageCount).map { Page(id: $0, thumbnail: thumbnails[$0] ?? nil) }
    }

    func rotate(_ id: Int) {
        guard let index = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[index].quarterTurns = (pages[index].quarterTurns + 1) % 4
    }

    func remove(_ id: Int) { pages.removeAll { $0.id == id } }

    /// Moves page `id` so it sits at position `target` (clamped).
    func move(_ id: Int, to target: Int) {
        guard let from = pages.firstIndex(where: { $0.id == id }), !pages.isEmpty else { return }
        let to = min(max(target, 0), pages.count - 1)
        guard to != from else { return }
        pages.insert(pages.remove(at: from), at: to)
    }
}

struct PDFOrganizeEditor: View {
    static let width: CGFloat = 560
    private static let columns = 4
    private static let cellWidth: CGFloat = 116
    private static let thumbHeight: CGFloat = 140
    /// Thumbnail, the 4 pt gap and the 24 pt button row.
    private static let rowHeight: CGFloat = 140 + 4 + 24
    private static let spacing: CGFloat = 12

    let title: String
    @ObservedObject var model: OrganizeModel
    let onClose: () -> Void
    let onApply: ([PageOp]) -> Void

    @State private var pointer: CGPoint?
    @Environment(\.glassRendering) private var rendering

    var body: some View {
        EditorShell(title: title, applyTitle: "Save", canApply: model.changed && !model.pages.isEmpty, onClose: onClose,
                    onApply: { onApply(model.operations) }, footerLeading: {
            Text(summary).font(.system(size: 12)).foregroundStyle(.secondary)
        }, content: {
            VStack(spacing: 12) {
                HStack {
                    ChoiceChip(title: "Reset", selected: false) { model.resetAll() }
                        .opacity(model.changed ? 1 : 0.4).disabled(!model.changed)
                    Spacer()
                    Text("Drag to reorder").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                grid
            }
        })
    }

    private var summary: String {
        if model.pages.count == model.pageCount { return "\(model.pageCount) \(model.pageCount == 1 ? "page" : "pages")" }
        return "\(model.pages.count) of \(model.pageCount) pages"
    }

    @ViewBuilder
    private var grid: some View {
        if let error = model.loadError {
            Text(error).font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 120)
        } else {
            Group {
                if rendering == .live {
                    ScrollView { gridWithDrag }
                } else {
                    gridWithDrag.frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(height: 2 * Self.rowHeight + Self.spacing + 44)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
    }

    private var gridWithDrag: some View {
        pageGrid
            .coordinateSpace(name: "organizeGrid")
            .overlay(alignment: .topLeading) { floating }
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.14), value: model.pages.map(\.id))
    }

    /// Live: a lazy grid. Snapshots (`ImageRenderer` draws neither lazy grids nor scroll views) get plain rows, unscrolled.
    @ViewBuilder
    private var pageGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(Self.cellWidth), spacing: Self.spacing), count: Self.columns)
        let numbered = Array(model.pages.enumerated())
        if rendering == .live {
            LazyVGrid(columns: columns, spacing: Self.spacing) {
                ForEach(numbered, id: \.element.id) { position, page in cell(page, position: position) }
            }
        } else {
            VStack(alignment: .leading, spacing: Self.spacing) {
                ForEach(Array(stride(from: 0, to: numbered.count, by: Self.columns)), id: \.self) { start in
                    HStack(spacing: Self.spacing) {
                        ForEach(numbered[start..<min(start + Self.columns, numbered.count)], id: \.element.id) { position, page in
                            cell(page, position: position)
                        }
                    }
                }
            }
        }
    }

    /// The thumbnail that follows the pointer while a page is dragged.
    @ViewBuilder
    private var floating: some View {
        if let id = model.dragging, let pointer, let page = model.pages.first(where: { $0.id == id }) {
            thumbnail(page).opacity(0.85).shadow(radius: 6).allowsHitTesting(false)
                .position(x: pointer.x, y: pointer.y)
        }
    }

    private func cell(_ page: OrganizeModel.Page, position: Int) -> some View {
        VStack(spacing: 4) {
            thumbnail(page)
                .opacity(model.dragging == page.id ? 0.3 : 1)
                .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("organizeGrid"))
                    .onChanged { drag in
                        if model.dragging != page.id { model.dragging = page.id }
                        pointer = drag.location
                        model.move(page.id, to: Self.position(at: drag.location, count: model.pages.count))
                    }
                    .onEnded { _ in
                        model.dragging = nil
                        pointer = nil
                    })
            HStack(spacing: 0) {
                iconButton("arrow.clockwise", help: "Rotate clockwise") { model.rotate(page.id) }
                Spacer(minLength: 0)
                Text("\(position + 1)").font(.system(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                iconButton("trash", help: "Delete page") { model.remove(page.id) }
            }
            .frame(width: Self.cellWidth, height: 24)
        }
    }

    private func thumbnail(_ page: OrganizeModel.Page) -> some View {
        let turned = page.quarterTurns % 2 != 0
        return ZStack {
            if let image = page.thumbnail {
                // Fitted before it is turned, into the turned cell, so the turned page fills the cell it sits in.
                Image(nsImage: image).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
                    .background(Color.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .frame(width: turned ? Self.thumbHeight : Self.cellWidth, height: turned ? Self.cellWidth : Self.thumbHeight)
                    .rotationEffect(.degrees(Double(page.quarterTurns % 4) * 90))
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: Self.cellWidth, height: Self.thumbHeight)
        .contentShape(Rectangle())
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium))
                .frame(width: 26, height: 22)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.08)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The grid position (0-based) under `point`, in the grid's own coordinates.
    private static func position(at point: CGPoint, count: Int) -> Int {
        let column = min(max(Int(point.x / (cellWidth + spacing)), 0), columns - 1)
        let row = max(Int(point.y / (rowHeight + spacing)), 0)
        return min(row * columns + column, max(count - 1, 0))
    }
}
