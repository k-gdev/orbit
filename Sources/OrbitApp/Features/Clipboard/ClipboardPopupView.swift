import AppKit
import Combine
import OrbitCore
import SwiftUI

/// What the popup shows: the search text, the matching entries and which one is selected. The
/// controller feeds it a snapshot of the history each time the popup opens.
@MainActor
final class ClipboardPopupState: ObservableObject {
    @Published var query = "" {
        didSet { if query != oldValue { refresh() } }
    }
    @Published private(set) var results: [ClipboardItem] = []
    @Published var selectedID: UUID?

    private var history = ClipboardHistory()
    /// Where the pointer was when the popup opened or last moved the selection with it; hovering only
    /// selects after the pointer really moves (otherwise scrolling with the arrow keys would fight it).
    private var lastPointer = NSPoint.zero

    /// Starts over with `history`: no search text, the newest entry selected.
    func reset(history: ClipboardHistory) {
        self.history = history
        query = ""
        refresh()
        selectedID = results.first?.id
        lastPointer = NSEvent.mouseLocation
    }

    var selected: ClipboardItem? {
        results.first { $0.id == selectedID }
    }

    /// Moves the selection by `delta` rows (clamped at both ends; no wrap, so the ends are obvious).
    func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = results.firstIndex { $0.id == selectedID } ?? (delta > 0 ? -1 : results.count)
        selectedID = results[min(max(current + delta, 0), results.count - 1)].id
    }

    /// The pointer is over `id`: select it, if the pointer has actually moved.
    func hover(_ id: UUID) {
        let pointer = NSEvent.mouseLocation
        guard abs(pointer.x - lastPointer.x) > 1 || abs(pointer.y - lastPointer.y) > 1 else { return }
        lastPointer = pointer
        selectedID = id
    }

    /// The history changed while the popup is up (a pin or a removal): list it again, keeping the search
    /// and, when it is still there, the selection.
    func reload(history: ClipboardHistory) {
        self.history = history
        refresh()
    }

    private func refresh() {
        results = history.search(query)
        if !results.contains(where: { $0.id == selectedID }) { selectedID = results.first?.id }
    }
}

/// The popup that opens at the pointer on the global shortcut: a search field, the history as compact
/// rows (↑/↓ to move, Return to choose, ⌘C / ⌘O / ⌘R to copy, open or reveal, Esc to close) and a hint
/// line. A row has a right-click menu and can be dragged out into another app.
struct ClipboardPopupView: View {
    @ObservedObject var state: ClipboardPopupState
    @ObservedObject var model: ClipboardModel
    /// "paste" when choosing an entry also presses ⌘V, "copy" when it only copies.
    let verb: String
    var autofocus = true
    let choose: (ClipboardItem) -> Void
    let cancel: () -> Void
    /// A row's menu asked for something other than choosing it.
    var perform: (ClipboardEntryAction, ClipboardItem) -> Void = { _, _ in }
    /// A row was dragged out and dropped somewhere.
    var dragEnded: () -> Void = {}

    static let width: CGFloat = 380
    static let rowHeight: CGFloat = 44
    static let maxVisibleRows = 8

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let visibleRows = min(max(state.results.count, 1), Self.maxVisibleRows)
        VStack(spacing: 0) {
            searchBar(style: style)
            Rectangle().fill(style.tileStroke).frame(height: 0.5)
            list(style: style)
                .frame(height: CGFloat(visibleRows) * Self.rowHeight + 10)
            Rectangle().fill(style.tileStroke).frame(height: 0.5)
            Text(ClipboardPopupShortcut.hint(verb: verb, for: state.selected))
                .font(.system(size: 10.5))
                .foregroundStyle(style.secondaryInk)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
        }
        .frame(width: Self.width)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous),
                                    tintOpacity: colorScheme == .dark ? 0.10 : 0.30))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func searchBar(style: PanelStyle) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(style.secondaryInk)
            PopupSearchField(text: $state.query, placeholder: "Search clipboard", autofocus: autofocus,
                             onMove: { state.move(by: $0) },
                             onSubmit: { if let item = state.selected { choose(item) } },
                             onCancel: cancel)
                .frame(height: 22)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
    }

    @ViewBuilder private func list(style: PanelStyle) -> some View {
        if state.results.isEmpty {
            VStack(spacing: 4) {
                Text(model.history.isEmpty ? "Nothing copied yet" : "No matches")
                    .font(.system(size: 13, weight: .semibold))
                Text(model.history.isEmpty ? "What you copy shows up here." : "Try different words.")
                    .font(.system(size: 11.5)).foregroundStyle(style.secondaryInk)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(state.results) { item in
                            ClipboardPopupRow(item: item, model: model, now: model.now(), isSelected: item.id == state.selectedID,
                                              choose: { choose(item) }, hover: { state.hover(item.id) },
                                              perform: { perform($0, item) }, dragEnded: dragEnded)
                                .id(item.id)
                        }
                    }
                    .padding(5)
                }
                .scrollIndicators(state.results.count > Self.maxVisibleRows ? .automatic : .never)
                .onChange(of: state.selectedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
    }
}

private struct ClipboardPopupRow: View {
    let item: ClipboardItem
    @ObservedObject var model: ClipboardModel
    let now: Date
    let isSelected: Bool
    let choose: () -> Void
    let hover: () -> Void
    let perform: (ClipboardEntryAction) -> Void
    let dragEnded: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let accent = PanelStyle.accent(for: colorScheme)
        HStack(spacing: 9) {
            ClipboardKindBadge(item: item, model: model, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.preview.isEmpty ? "(empty)" : item.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                ClipboardMetaLine(item: item, model: model, now: now)
            }
            Spacer(minLength: 4)
            if item.pinned {
                Image(systemName: "pin.fill").font(.system(size: 10)).foregroundStyle(accent)
            }
            if isSelected {
                Image(systemName: "return").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(style.secondaryInk)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: ClipboardPopupView.rowHeight)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? accent.opacity(colorScheme == .dark ? 0.30 : 0.16) : Color.clear)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.55) : Color.clear, lineWidth: 1))
        )
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            ClipboardRowSurface(label: item.preview,
                                onClick: choose,
                                onHover: { inside in if inside { hover() } },
                                dragContent: { model.dragContent(for: item) },
                                onDragEnded: { operation in if operation != [] { dragEnded() } },
                                menu: { ClipboardEntryMenu.entries(for: item, files: model.checkFiles(of: item)) },
                                onMenuAction: perform)
        }
        .task(id: item.id) { await model.refreshFileStatus(of: item) }
    }
}

// MARK: Search field

/// A plain text field that takes keyboard focus as soon as it is in a window, and reports ↑ ↓ Return
/// and Esc to its owner instead of acting on them (AppKit's own field handles typing, caret movement,
/// copy and paste and input methods). Used instead of SwiftUI's `TextField` so the popup is ready to
/// type in the moment it appears, without relying on SwiftUI's focus handling in a non-activating panel.
struct PopupSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var autofocus = true
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusingTextField {
        let field = FocusingTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 15)
        field.placeholderString = placeholder
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = context.coordinator
        field.wantsFocus = autofocus
        return field
    }

    func updateNSView(_ field: FocusingTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PopupSearchField
        init(parent: PopupSearchField) { self.parent = parent }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveUp(_:)): parent.onMove(-1)
            case #selector(NSResponder.moveDown(_:)): parent.onMove(1)
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit()
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel()
            default: return false
            }
            return true
        }
    }
}

final class FocusingTextField: NSTextField {
    var wantsFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard wantsFocus, window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
}
