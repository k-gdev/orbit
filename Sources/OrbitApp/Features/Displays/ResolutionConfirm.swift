import AppKit
import OrbitCore
import SwiftUI

/// "Keep this resolution?" after a resolution change, which is applied (permanently) before the question is
/// asked. Shown two ways at once: a floating card centred on the display that changed (it stays up even
/// when the menu bar panel closes or its display changes size) and a row in that display's tile in the panel.
/// Revert, or 15 s without an answer, puts the previous mode back.
struct ResolutionConfirmCard: View {
    @ObservedObject var model: DisplaysModel
    /// The compact row inside a panel tile instead of the floating card.
    var compact = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let confirmation = model.confirmation {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if compact { row(confirmation, now: context.date) } else { card(confirmation, now: context.date) }
            }
        }
    }

    private func card(_ confirmation: ResolutionConfirmation, now: Date) -> some View {
        let style = PanelStyle.colors(for: colorScheme)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "display").font(.system(size: 20, weight: .medium)).foregroundStyle(PanelStyle.accent(for: colorScheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Keep this resolution?").font(.system(size: 14, weight: .semibold))
                    Text("\(confirmation.displayTitle): \(confirmation.proposedLabel)")
                        .font(.system(size: 12)).foregroundStyle(style.secondaryInk).lineLimit(1).truncationMode(.middle)
                }
            }
            HStack(spacing: 8) {
                Text(confirmation.countdown(at: now)).font(.system(size: 12)).monospacedDigit().foregroundStyle(style.secondaryInk)
                Spacer(minLength: 12)
                buttons
            }
        }
        .padding(14)
        .frame(width: 330)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: 16, style: .continuous), tintOpacity: 0.3))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func row(_ confirmation: ResolutionConfirmation, now: Date) -> some View {
        let style = PanelStyle.colors(for: colorScheme)
        return HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Keep \(confirmation.proposedLabel)?").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                Text(confirmation.countdown(at: now)).font(.system(size: 11)).monospacedDigit().foregroundStyle(style.secondaryInk)
            }
            Spacer(minLength: 6)
            buttons
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(OrbitTheme.accent.opacity(colorScheme == .dark ? 0.22 : 0.12)))
    }

    private var buttons: some View {
        let style = PanelStyle.colors(for: colorScheme)
        return HStack(spacing: 6) {
            Button { model.revertResolution() } label: {
                Text("Revert").font(.system(size: 12, weight: .medium)).foregroundStyle(style.inkOnTrack)
                    .padding(.horizontal, 11).padding(.vertical, 4.5)
                    .background(Capsule().fill(style.controlFill))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Button { model.keepResolution() } label: {
                Text("Keep").font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 13).padding(.vertical, 4.5)
                    .background(Capsule().fill(OrbitTheme.accent))
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// The floating card's window: a borderless, non-activating panel above the menu bar panel, on every Space,
/// centred on the display that changed and re-centred when that display's size changes.
@MainActor
final class ResolutionConfirmWindow {
    private var panel: NSPanel?
    private var displayID: CGDirectDisplayID = 0

    func show(model: DisplaysModel, on id: CGDirectDisplayID) {
        displayID = id
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: ResolutionConfirmCard(model: model).fixedSize())
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        reposition()
        panel.orderFrontRegardless()
        // Key (without activating Orbit), so Return keeps and Esc reverts without a click first.
        panel.makeKey()
    }

    /// Centres the card on its display (call after display changes).
    func reposition() {
        guard let panel else { return }
        let screen = NSScreen.screens.first { DisplayIdentity.displayID(for: $0) == displayID } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    private func makePanel() -> NSPanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 100),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = GlassRendering.windowHasShadow
        panel.isReleasedWhenClosed = false
        return panel
    }
}

/// A borderless panel that can take key status (so Return keeps and the buttons answer the first click)
/// without activating Orbit.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
