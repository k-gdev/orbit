import AppKit
import OrbitCore
import SwiftUI

/// What the Clipboard tab can ask the feature to do beyond editing the history.
struct ClipboardPanelActions {
    /// Copy an entry back to the pasteboard, or open or reveal its files (and close the panel).
    var perform: (ClipboardEntryAction, ClipboardItem) -> Void = { _, _ in }
}

/// The Clipboard tab of the menu bar panel: a search field and a Clear button pinned at the top, then
/// the history as tiles (pinned entries first), each with its kind, preview, source app and age.
/// Clicking a tile copies it; pin, delete and (for files) open appear on hover, and the context menu has
/// the rest. A tile can also be dragged out into another app. Scrolls itself
/// (`ClipboardFeature.managesOwnScrolling`), so the search field stays put.
struct ClipboardPanelView: View {
    @ObservedObject var model: ClipboardModel
    @ObservedObject var settings: ClipboardSettings
    let actions: ClipboardPanelActions

    @State private var query: String
    @State private var confirmingClear = false
    @State private var listContentHeight: CGFloat = 0
    @Environment(\.panelContentMaxHeight) private var contentMaxHeight
    @Environment(\.colorScheme) private var colorScheme

    init(model: ClipboardModel, settings: ClipboardSettings, actions: ClipboardPanelActions, initialQuery: String = "") {
        self.model = model
        self.settings = settings
        self.actions = actions
        _query = State(initialValue: initialQuery)
    }

    /// Room the search row and the hint take above and below the list.
    private let chromeHeight: CGFloat = 78
    private let listCap: CGFloat = 450

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let now = model.now()
        let shown = model.history.search(query)
        let searching = !query.trimmingCharacters(in: .whitespaces).isEmpty
        let pinned = shown.filter(\.pinned)
        let recent = shown.filter { !$0.pinned }
        let listMax = max(120, min(listCap, contentMaxHeight - chromeHeight))

        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                searchField(style: style)
                clearButton(style: style)
            }
            if model.history.isEmpty {
                emptyTile(symbol: "doc.on.clipboard", title: "Nothing copied yet",
                          detail: settings.recordPasswords
                              ? "What you copy shows up here. Copies from password managers are kept only until Orbit quits."
                              : "What you copy shows up here. Copies from password managers are never recorded.")
            } else if shown.isEmpty {
                emptyTile(symbol: "magnifyingglass", title: "No matches", detail: "Nothing in the history matches “\(query)”.")
            } else {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if searching {
                            PanelSectionHeader("Results")
                            rows(shown, now: now)
                        } else {
                            if !pinned.isEmpty {
                                PanelSectionHeader("Pinned")
                                rows(pinned, now: now)
                            }
                            if !recent.isEmpty {
                                PanelSectionHeader("Recent")
                                    .padding(.top, pinned.isEmpty ? 0 : 4)
                                rows(recent, now: now)
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .background(GeometryReader { geo in
                        Color.clear.preference(key: ClipboardListHeightKey.self, value: geo.size.height)
                    })
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollIndicators(listContentHeight > listMax ? .automatic : .never)
                .frame(height: min(max(listContentHeight, 1), listMax))
                .onPreferenceChange(ClipboardListHeightKey.self) { listContentHeight = $0 }
            }
            Text("\(settings.popupShortcut.display) opens this list from anywhere")
                .font(.system(size: 10.5))
                .foregroundStyle(style.secondaryInk)
                .frame(maxWidth: .infinity)
                .padding(.top, 2)
        }
        .onAppear { model.enforceLimits() }
    }

    // MARK: Pieces

    @ViewBuilder private func rows(_ items: [ClipboardItem], now: Date) -> some View {
        ForEach(items) { item in
            ClipboardPanelRow(item: item, model: model, now: now, perform: { actions.perform($0, item) })
        }
    }

    private func searchField(style: PanelStyle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(style.secondaryInk)
            TextField("Search clipboard", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                }
                .buttonStyle(.plain)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tileFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tileStroke, lineWidth: 0.5))
    }

    private func clearButton(style: PanelStyle) -> some View {
        let removable = model.history.items.filter { !$0.pinned }.count
        return Button {
            if confirmingClear {
                confirmingClear = false
                model.clear(keepPinned: true)
            } else {
                confirmingClear = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { confirmingClear = false }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: confirmingClear ? "trash.fill" : "trash").font(.system(size: 11, weight: .medium))
                Text(confirmingClear ? "Clear \(removable)?" : "Clear").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(confirmingClear ? Color.white : style.inkOnTrack)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(confirmingClear ? Color.red.opacity(0.85) : style.tileFill))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(confirmingClear ? Color.clear : style.tileStroke, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(removable == 0)
        .opacity(removable == 0 ? 0.45 : 1)
        .help("Remove every entry except the pinned ones")
    }

    private func emptyTile(symbol: String, title: String, detail: String) -> some View {
        PanelTile(spacing: 8, padding: 16) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 22)).foregroundStyle(PanelStyle.accent(for: colorScheme))
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

private struct ClipboardListHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// One history entry as a tile in the panel.
private struct ClipboardPanelRow: View {
    let item: ClipboardItem
    @ObservedObject var model: ClipboardModel
    let now: Date
    /// Copy, open or reveal this entry (the feature does it).
    let perform: (ClipboardEntryAction) -> Void

    @State private var hovering = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let filesUsable = model.fileStatuses[item.id]?.isUsable ?? true
        PanelTile(spacing: 0, padding: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 9) {
                    ClipboardKindBadge(item: item, model: model)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.preview.isEmpty ? "(empty)" : item.preview)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        ClipboardMetaLine(item: item, model: model, now: now)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
                .overlay {
                    ClipboardRowSurface(label: item.preview, toolTip: "Copy",
                                        onClick: { perform(.copy) },
                                        dragContent: { model.dragContent(for: item) },
                                        menu: { ClipboardEntryMenu.entries(for: item, files: model.checkFiles(of: item)) },
                                        onMenuAction: handleMenuAction)
                }

                if hovering || item.pinned {
                    HStack(spacing: 4) {
                        if hovering && item.kind == .files {
                            rowButton("arrow.up.forward.app", on: false, help: "Open", style: style) { perform(.open) }
                                .disabled(!filesUsable)
                                .opacity(filesUsable ? 1 : 0.4)
                        }
                        if !item.concealed {
                            rowButton(item.pinned ? "pin.fill" : "pin", on: item.pinned, help: item.pinned ? "Unpin" : "Pin", style: style) {
                                model.togglePin(item.id)
                            }
                        }
                        if hovering {
                            rowButton("xmark", on: false, help: "Remove from the history", style: style) { model.remove(item.id) }
                        }
                    }
                }
            }
        }
        .onHover { hovering = $0 }
        .task(id: item.id) { await model.refreshFileStatus(of: item) }
    }

    /// Pin and remove are the model's; everything else goes to the feature.
    private func handleMenuAction(_ action: ClipboardEntryAction) {
        switch action {
        case .pin, .unpin: model.togglePin(item.id)
        case .remove: model.remove(item.id)
        case .copy, .open, .showInFinder, .openInPreview: perform(action)
        }
    }

    private func rowButton(_ symbol: String, on: Bool, help: String, style: PanelStyle, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(on ? Color.white : style.inkOnTrack)
                .frame(width: 22, height: 22)
                .background(Circle().fill(on ? OrbitTheme.accent : style.trackFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
