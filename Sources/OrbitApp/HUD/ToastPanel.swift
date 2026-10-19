import AppKit
import Combine
import OrbitCore
import SwiftUI

/// What a toast says and offers.
struct ToastContent {
    var message: String
    var detail: String?
    var isError = false
    var canOpen = false
    var canReveal = false
    var canUndo = false
}

struct ToastActions {
    var open: () -> Void = {}
    var reveal: () -> Void = {}
    var undo: () -> Void = {}
}

struct ToastView: View {
    let content: ToastContent
    let actions: ToastActions

    static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if content.isError {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(OrbitTheme.accent)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(content.message)
                        .font(.system(size: 14, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail = content.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            if content.canOpen || content.canReveal || content.canUndo {
                HStack(spacing: 8) {
                    if content.canOpen { chip("Open", actions.open) }
                    if content.canReveal { chip("Show in Finder", actions.reveal) }
                    if content.canUndo { chip("Undo", actions.undo) }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 20, style: .continuous)))
    }

    private func chip(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(Color.primary.opacity(0.10)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Stacks toasts at the top right of the screen holding the pointer, below the menu bar.
/// A toast dismisses itself after 6 s; hovering pauses its timer.
@MainActor
final class ToastCenter {
    static let lifetime: TimeInterval = 6

    private final class Entry {
        let panel: HUDPanel
        var hovering = false
        var task: Task<Void, Never>?
        init(panel: HUDPanel) { self.panel = panel }
    }

    private var entries: [Entry] = []

    /// Returns a closure that dismisses this toast early.
    @discardableResult
    func show(_ content: ToastContent, actions: ToastActions = ToastActions()) -> () -> Void {
        var entryRef: Entry?
        let panel = HUDPanel(rootView: ToastView(content: content, actions: actions)) { hovering in
            entryRef?.hovering = hovering
        }
        let entry = Entry(panel: panel)
        entryRef = entry
        entries.append(entry)
        layout(animated: false)
        panel.orderFrontRegardless()
        entry.task = Task { [weak self, weak entry] in
            var elapsed: TimeInterval = 0
            while elapsed < Self.lifetime {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
                if entry?.hovering != true { elapsed += 0.1 }
            }
            if let self, let entry { self.dismiss(entry) }
        }
        return { [weak self] in self?.dismiss(entry) }
    }

    private func dismiss(_ entry: Entry) {
        entry.task?.cancel()
        entry.panel.orderOut(nil)
        entries.removeAll { $0 === entry }
        layout(animated: true)
    }

    private func layout(animated: Bool) {
        let bounds = HUDPlacement.visibleFrame(containing: NSEvent.mouseLocation)
        var top = bounds.maxY - 12
        for entry in entries {
            let size = entry.panel.frame.size
            let frame = NSRect(x: bounds.maxX - 12 - size.width, y: top - size.height, width: size.width, height: size.height)
            if entry.panel.isVisible && animated {
                entry.panel.animator().setFrame(frame, display: true)
            } else {
                entry.panel.setFrame(frame, display: false)
            }
            top = frame.minY - 8
        }
    }
}
