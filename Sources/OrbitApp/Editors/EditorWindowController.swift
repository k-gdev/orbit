import AppKit
import SwiftUI

/// The glass rounded panel every editor sits in: × at top left, a centered title, and an orange
/// Apply at bottom right (the hero's "Crop Video" window).
struct EditorShell<Content: View, Leading: View>: View {
    let title: String
    var applyTitle = "Apply"
    var canApply = true
    let onClose: () -> Void
    let onApply: () -> Void
    @ViewBuilder var footerLeading: () -> Leading
    @ViewBuilder var content: () -> Content

    @Environment(\.glassRendering) private var rendering

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content().padding(16)
            Divider().opacity(0.5)
            footer
        }
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 28, style: .continuous), tintOpacity: 0.3))
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var header: some View {
        ZStack {
            Text(title).font(.system(size: 17, weight: .semibold)).lineLimit(1)
            HStack {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .help("Close without saving")
                Spacer()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background { if rendering == .live { WindowDragHandle() } }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            footerLeading()
            Spacer(minLength: 0)
            Button(action: onApply) {
                Text(applyTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(EditorStyle.accent))
                    .opacity(canApply ? 1 : 0.45)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!canApply)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

extension EditorShell where Leading == EmptyView {
    init(title: String, applyTitle: String = "Apply", canApply: Bool = true, onClose: @escaping () -> Void,
         onApply: @escaping () -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, applyTitle: applyTitle, canApply: canApply, onClose: onClose, onApply: onApply,
                  footerLeading: { EmptyView() }, content: content)
    }
}

/// Lets the header drag the borderless window.
private struct WindowDragHandle: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// A borderless panel that can take keyboard focus (the editors have text fields).
final class EditorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init(size: CGSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless],
                   backing: .buffered, defer: true)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
    }

    override func cancelOperation(_ sender: Any?) { close() }
}

/// Shows one editor in its own panel, keeps it alive until it closes, and reports the close.
@MainActor
final class EditorWindowController: NSObject, NSWindowDelegate {
    private static var live: [EditorWindowController] = []

    private let panel: EditorPanel
    private var onClose: (() -> Void)?

    /// The panel's center, for opening the next editor of a batch in the same place.
    var center: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }

    /// Opens an editor `width` wide (its height is what the content needs) centered on `center`, or on the screen holding the pointer. `content` gets a closure
    /// that closes the panel. `onClose` runs once, however the panel closes.
    @discardableResult
    static func present<V: View>(width: CGFloat, center: CGPoint? = nil, onClose: (() -> Void)? = nil,
                                 @ViewBuilder content: (_ close: @escaping () -> Void) -> V) -> EditorWindowController {
        var closer: () -> Void = {}
        let host = NSHostingView(rootView: content { closer() }.frame(width: width))
        host.sizingOptions = []
        let size = CGSize(width: width, height: host.fittingSize.height)
        host.frame = NSRect(origin: .zero, size: size)
        let controller = EditorWindowController(size: size)
        closer = { [weak controller] in controller?.close() }
        controller.onClose = onClose
        controller.panel.contentView = host
        controller.place(size: size, center: center)
        live.append(controller)
        NSApp.activate()
        controller.panel.makeKeyAndOrderFront(nil)
        return controller
    }

    private init(size: CGSize) {
        panel = EditorPanel(size: size)
        super.init()
        panel.delegate = self
    }

    private func place(size: CGSize, center: CGPoint?) {
        let anchor = center ?? NSEvent.mouseLocation
        let screen = HUDPlacement.visibleFrame(containing: anchor)
        let target = center ?? CGPoint(x: screen.midX, y: screen.midY)
        var frame = NSRect(x: target.x - size.width / 2, y: target.y - size.height / 2, width: size.width, height: size.height)
        frame = HUDPlacement.clamp(frame, to: screen)
        panel.setFrame(frame, display: false)
    }

    func close() { panel.close() }

    func windowWillClose(_ notification: Notification) {
        let handler = onClose
        onClose = nil
        Self.live.removeAll { $0 === self }
        handler?()
    }
}
