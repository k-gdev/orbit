import AppKit
import OrbitCore
import SwiftUI

/// The content of the floating shelf: a header (title, count, drag-all, Clear, close) over a grid of file
/// tiles, or a drop prompt when the shelf is empty. It draws its own glass; the panel around it is clear.
struct ShelfStripView: View {
    @ObservedObject var model: ShelfModel
    let close: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private static let corner: CGFloat = 20

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Self.corner, style: .continuous)
        VStack(spacing: 0) {
            header
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Pressing on any bare part of the shelf moves the window; tiles and buttons above take their own clicks.
        .background(ShelfWindowHandle())
        .background(GlassBackground(shape: shape, tintOpacity: colorScheme == .dark ? 0.10 : 0.30))
        .overlay(dropHighlight(shape))
        .clipShape(shape)
    }

    // MARK: Header

    private var header: some View {
        let style = PanelStyle.colors(for: colorScheme)
        return HStack(spacing: 8) {
            Image(systemName: model.urls.isEmpty ? "tray" : "tray.full")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PanelStyle.accent(for: colorScheme))
            Text("Shelf").font(.system(size: 13, weight: .semibold))
            Text(Self.countText(model.urls.count, offline: model.unreachable.count))
                .font(.system(size: 11)).foregroundStyle(style.secondaryInk)
                .lineLimit(1)
            Spacer(minLength: 8)
            if model.availableURLs.count > 1 { dragAllChip(style) }
            if !model.urls.isEmpty { clearButton(style) }
            closeButton(style)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    /// "Empty", "1 file", "5 files", and ", 2 offline" when some can't be reached right now.
    static func countText(_ count: Int, offline: Int = 0) -> String {
        let base: String
        switch count {
        case 0: return "Empty"
        case 1: base = "1 file"
        default: base = "\(count) files"
        }
        return offline > 0 ? "\(base), \(offline) offline" : base
    }

    private func dragAllChip(_ style: PanelStyle) -> some View {
        ZStack {
            HStack(spacing: 4) {
                Image(systemName: "square.on.square").font(.system(size: 10, weight: .semibold))
                Text("Drag all").font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(style.inkOnTrack)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(style.controlFill))
            ShelfDragSource(urls: model.availableURLs, toolTip: "Drag every file on the shelf at once",
                            onMovedOut: { model.verifyMoved($0) })
        }
        .fixedSize()
    }

    private func clearButton(_ style: PanelStyle) -> some View {
        Button { model.clear() } label: {
            Text("Clear")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(style.inkOnTrack)
                .padding(.horizontal, 9).padding(.vertical, 4)
                .background(Capsule().fill(style.controlFill))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Take everything off the shelf (the files stay where they are)")
    }

    private func closeButton(_ style: PanelStyle) -> some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(style.inkOnTrack)
                .frame(width: 22, height: 22)
                .background(Circle().fill(style.controlFill))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Close the shelf (its files stay on it)")
    }

    // MARK: Body

    @ViewBuilder private var content: some View {
        if model.urls.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: ShelfTile.size.width, maximum: ShelfTile.size.width + 14), spacing: 2)],
                          alignment: .leading, spacing: 2) {
                    ForEach(model.urls, id: \.self) { url in ShelfTile(url: url, model: model) }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
            }
        }
    }

    private var emptyState: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let accent = PanelStyle.accent(for: colorScheme)
        return VStack(spacing: 5) {
            Image(systemName: "arrow.down.to.line").font(.system(size: 18, weight: .medium)).foregroundStyle(accent)
            Text("Drop files here").font(.system(size: 13, weight: .medium))
            Text("They stay on the shelf until you take them off.").font(.system(size: 11)).foregroundStyle(style.secondaryInk)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(accent.opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
    }

    private func dropHighlight(_ shape: RoundedRectangle) -> some View {
        let accent = PanelStyle.accent(for: colorScheme)
        return ZStack {
            shape.fill(accent.opacity(0.14))
            shape.strokeBorder(accent, lineWidth: 2.5)
        }
        .opacity(model.isDropTargeted ? 1 : 0)
        .allowsHitTesting(false)
    }
}

/// One file on the shelf: its icon or preview and name. Drag it out to move or copy the file where it
/// goes (the destination decides, as in Finder); hover shows a ✕; double-click opens; right-click has a menu.
struct ShelfTile: View {
    let url: URL
    @ObservedObject var model: ShelfModel

    @State private var hovering = false
    @State private var thumbnail: NSImage?
    @Environment(\.shelfPreviewHover) private var previewHover

    static let size = CGSize(width: 76, height: 86)

    init(url: URL, model: ShelfModel) {
        self.url = url
        self.model = model
        _thumbnail = State(initialValue: ShelfThumbnails.cached(url))
    }

    var body: some View {
        let offline = model.unreachable.contains(url)
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hovering ? Color.primary.opacity(0.09) : Color.clear)
            VStack(spacing: 5) {
                Image(nsImage: thumbnail ?? ShelfIcon.icon(for: url))
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .frame(width: 44, height: 44)
                    // A page or picture preview gets soft corners and a hairline of depth; a plain icon
                    // has transparent edges, so the same treatment hides in it.
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 1.2, y: 0.8)
                    .opacity(offline ? 0.4 : 1)
                    .overlay(alignment: .bottomTrailing) { if offline { ShelfOfflineBadge().offset(x: 5, y: 4) } }
                Text(url.lastPathComponent)
                    .font(.system(size: 10.5))
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .opacity(offline ? 0.55 : 1)
            }
            .padding(.horizontal, 4)
            .padding(.top, 7)
            .frame(maxHeight: .infinity, alignment: .top)
            // An item that can't be reached can't be dragged or opened, only removed.
            ShelfDragSource(urls: offline ? [] : [url],
                            toolTip: offline ? "\(url.path)\n\(ShelfOffline.hint)" : url.path,
                            removeButton: .topTrailing,
                            onHover: { hovering = $0 },
                            onOpen: { if !offline { NSWorkspace.shared.open(url) } },
                            onRemove: { model.remove(url) },
                            onMovedOut: { model.verifyMoved($0) },
                            menu: { ShelfMenus.entries(for: url, offline: offline, remove: { model.remove(url) },
                                                        trash: { model.moveToTrash(url) }) },
                            simulatesHover: previewHover == url)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .task(id: ThumbnailKey(url: url, offline: offline)) {
            // No preview for a file that can't be reached (the check itself could stall).
            guard !offline else { return }
            if let fresh = await ShelfThumbnails.load(url, side: 48) { thumbnail = fresh }
        }
    }

    private struct ThumbnailKey: Hashable {
        let url: URL
        let offline: Bool
    }
}

/// Why an item is dimmed.
enum ShelfOffline {
    static let hint = "Can't reach this file right now: its drive may be disconnected or asleep. It stays on the shelf until you remove it."
}

/// The small warning mark on a dimmed item's icon.
struct ShelfOfflineBadge: View {
    var body: some View {
        Image(systemName: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.orange)
            .padding(2)
            .background(Circle().fill(Color.white.opacity(0.9)))
    }
}

/// The right-click menu of a shelf entry. What it offers is decided by `ShelfMenuLayout`: an item that can't be
/// reached right now offers only what still works.
enum ShelfMenus {
    static func entries(for url: URL, offline: Bool = false, remove: @escaping () -> Void,
                        trash: @escaping () -> Void) -> [ShelfMenuEntry] {
        ShelfMenuLayout.items(offline: offline).map { item in
            switch item {
            case .separator:
                return .separator
            case .command(let command):
                return .action(command.title, action(for: command, url: url, remove: remove, trash: trash))
            }
        }
    }

    private static func action(for command: ShelfMenuCommand, url: URL, remove: @escaping () -> Void,
                               trash: @escaping () -> Void) -> () -> Void {
        switch command {
        case .open:
            return { NSWorkspace.shared.open(url) }
        case .showInFinder:
            return { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .copyPath:
            return {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        case .moveToTrash:
            return trash
        case .removeFromShelf:
            return remove
        }
    }
}

/// A transparent AppKit view that moves the window when pressed. Put it behind content: the entries and
/// buttons above it still get their own clicks, and a press on bare glass drags the shelf.
struct ShelfWindowHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> ShelfWindowHandleView { ShelfWindowHandleView() }
    func updateNSView(_ view: ShelfWindowHandleView, context: Context) {}
}

final class ShelfWindowHandleView: NSView {
    override var isOpaque: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false } // `performDrag` does the moving
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}
