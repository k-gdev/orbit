import AppKit
import OrbitCore
import SwiftUI

/// One window in the Dock preview.
struct DockPreviewItem: Identifiable {
    let id: String
    let title: String
    let isMinimised: Bool
    /// The captured thumbnail; nil until it arrives, or for good (minimised, no Screen Recording, capture failed).
    var thumbnail: CGImage?
}

/// What the Dock preview strip shows. The controller fills it; the strip only draws it.
@MainActor
final class DockPreviewModel: ObservableObject {
    @Published var appName = ""
    @Published var appIcon: NSImage?
    @Published var items: [DockPreviewItem] = []
    @Published var layout: DockPreviewLayout?
    /// The thumbnail under the pointer (its title replaces the app's name in the title line).
    @Published var hovered: Int?

    func setThumbnail(_ image: CGImage, at index: Int) {
        guard items.indices.contains(index) else { return }
        items[index].thumbnail = image
    }

    func clear() {
        items = []
        layout = nil
        hovered = nil
        appIcon = nil
    }
}

/// The glass strip: a title line (the app, or the window under the pointer) over the window thumbnails,
/// laid out by `DockPreviewLayout`.
struct DockPreviewStrip: View {
    @ObservedObject var model: DockPreviewModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let layout = model.layout {
            let size = layout.stripFrame.size
            ZStack(alignment: .topLeading) {
                GlassBackground(shape: RoundedRectangle(cornerRadius: 18, style: .continuous), tintOpacity: 0.08)
                header
                    .frame(width: layout.headerFrame.width, height: layout.headerFrame.height)
                    .offset(x: layout.headerFrame.minX, y: layout.headerFrame.minY)
                ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                    if layout.thumbnailFrames.indices.contains(index) {
                        let frame = layout.thumbnailFrames[index]
                        DockPreviewCell(item: item, icon: model.appIcon, isHovered: model.hovered == index)
                            .frame(width: frame.width, height: frame.height)
                            .offset(x: frame.minX, y: frame.minY)
                    }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(model.appName) windows")
        }
    }

    private var header: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let hoveredTitle = model.hovered.flatMap { model.items.indices.contains($0) ? model.items[$0].title : nil }
        return HStack(spacing: 6) {
            AppIconImage(icon: model.appIcon, size: 16)
            Text(hoveredTitle ?? model.appName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(style.inkOnTrack)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            Text(model.items.count == 1 ? "1 window" : "\(model.items.count) windows")
                .font(.system(size: 11))
                .foregroundStyle(style.secondaryInk)
                .fixedSize()
        }
    }
}

/// One thumbnail: the captured image, or a card with the app's icon and the window's title.
private struct DockPreviewCell: View {
    let item: DockPreviewItem
    let icon: NSImage?
    let isHovered: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        GeometryReader { geo in
            ZStack {
                shape.fill(colorScheme == .dark ? Color.white.opacity(0.07) : Color.white.opacity(0.55))
                if let thumbnail = item.thumbnail {
                    Image(decorative: thumbnail, scale: 2)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 6) {
                        AppIconImage(icon: icon, size: min(44, geo.size.height * 0.36))
                            .opacity(item.isMinimised ? 0.6 : 1)
                        Text(item.title)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(style.inkOnTrack)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .padding(.horizontal, 8)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .clipShape(shape)
        .overlay(shape.strokeBorder(isHovered ? PanelStyle.accent(for: colorScheme) : style.tileStroke.opacity(2),
                                    lineWidth: isHovered ? 2.5 : 0.5))
        .overlay(alignment: .bottomLeading) {
            if item.isMinimised {
                Label("Minimised", systemImage: "minus.rectangle")
                    .font(.system(size: 10, weight: .semibold))
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(style.inkOnTrack)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(colorScheme == .dark ? Color.black.opacity(0.45) : Color.white.opacity(0.85)))
                    .padding(6)
            }
        }
        .shadow(color: .black.opacity(isHovered ? 0.28 : 0.16), radius: isHovered ? 5 : 2.5, y: 1)
        .scaleEffect(isHovered ? 1.025 : 1)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .accessibilityElement()
        .accessibilityLabel("\(item.title)\(item.isMinimised ? ", minimised" : "")")
        .accessibilityAddTraits(.isButton)
    }
}

/// The non-activating, borderless panel holding the strip above the Dock. It never becomes key, never
/// activates Orbit, and passes every click to `onClick` (the controller hit-tests the thumbnails itself,
/// since hover tracking is unreliable in a panel of an inactive app).
final class DockPreviewPanel: NSPanel {
    private let container: DockPreviewContainerView

    init(model: DockPreviewModel, onClick: @escaping () -> Void) {
        container = DockPreviewContainerView(rootView: DockPreviewStrip(model: model))
        container.onClick = onClick
        super.init(contentRect: NSRect(x: 0, y: 0, width: 200, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentView = container
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle, .transient]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The controller places the strip itself (clamped by `DockPreviewLayout`).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Hosts the strip and takes every mouse-down inside it.
private final class DockPreviewContainerView: NSView {
    var onClick: (() -> Void)?
    private let host: NSHostingView<DockPreviewStrip>

    init(rootView: DockPreviewStrip) {
        host = NSHostingView(rootView: rootView)
        super.init(frame: .zero)
        host.translatesAutoresizingMaskIntoConstraints = false
        addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: leadingAnchor), host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.topAnchor.constraint(equalTo: topAnchor), host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
