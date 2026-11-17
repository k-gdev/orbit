import AppKit
import OrbitCore
import SwiftUI

/// The Windows tab: every running app (frontmost first) with bring to front, hide/show and quit / force
/// quit, and, expanded, its windows (click one to bring it forward; minimise or restore; close). Without
/// Accessibility the app actions still work and the window list offers the permission instead.
struct WindowsPanelView: View {
    @ObservedObject var model: WindowsPanelModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        VStack(alignment: .leading, spacing: 6) {
            PanelSectionHeader("Running apps", trailing: AnyView(
                Text(model.apps.count == 1 ? "1 app" : "\(model.apps.count) apps")
                    .font(.system(size: 11)).foregroundStyle(style.secondaryInk)))
            if model.apps.isEmpty {
                PanelTile {
                    Text("No apps are running.").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                }
            } else {
                ForEach(model.apps) { app in
                    WindowsAppTile(app: app, model: model)
                }
                if model.hasAccessibility {
                    // Accessibility only reaches the current Space (plus minimised windows); say so.
                    Text("Window lists show this Space and minimised windows. With Screen Recording, the Dock preview also shows other Spaces.")
                        .font(.system(size: 11))
                        .foregroundStyle(style.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            }
        }
    }
}

/// One app: its row of actions, a force-quit confirmation when asked, and its windows when expanded.
private struct WindowsAppTile: View {
    let app: WindowsAppRow
    @ObservedObject var model: WindowsPanelModel

    @Environment(\.colorScheme) private var colorScheme

    private var isExpanded: Bool { model.expanded.contains(app.id) }
    private var name: String { app.info.name }

    var body: some View {
        PanelTile(spacing: 6, padding: 7) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { model.toggleExpanded(app) }
                } label: {
                    header
                }
                .buttonStyle(.plain)
                .help(isExpanded ? "Hide \(name)'s windows" : "Show \(name)'s windows")
                .accessibilityLabel("\(name), \(subtitleText)")
                .accessibilityHint(isExpanded ? "Collapses the window list" : "Expands the window list")

                PanelRoundButton(systemImage: "arrow.up.forward.app", size: 26) { model.focus(app) }
                    .help("Bring \(name) to the front")
                    .accessibilityLabel("Bring \(name) to the front")
                PanelRoundButton(systemImage: app.info.isHidden ? "eye" : "eye.slash", size: 26) { model.toggleHidden(app) }
                    .help(app.info.isHidden ? "Show \(name)" : "Hide \(name)")
                    .accessibilityLabel(app.info.isHidden ? "Show \(name)" : "Hide \(name)")
                PanelRoundMenu(systemImage: "power", size: 26) {
                    Button("Quit \(name)") { model.quit(app) }
                    Divider()
                    Button("Force Quit \(name)…") { model.askToForceQuit(app) }
                }
                .help("Quit \(name)")
                .accessibilityLabel("Quit \(name)")
            }
            if model.confirmingForceQuit == app.id {
                ForceQuitConfirmation(name: name, cancel: model.cancelForceQuit, confirm: model.confirmForceQuit)
            }
            if isExpanded {
                windowList
            }
        }
        .contextMenu {
            Button("Bring to Front") { model.focus(app) }
            Button(app.info.isHidden ? "Show" : "Hide") { model.toggleHidden(app) }
            Divider()
            Button("Quit") { model.quit(app) }
            Button("Force Quit…") { model.askToForceQuit(app) }
        }
    }

    private var header: some View {
        let style = PanelStyle.colors(for: colorScheme)
        return HStack(spacing: 7) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(style.secondaryInk)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            AppIconImage(icon: app.icon, size: 26)
                .opacity(app.info.isHidden ? 0.5 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                subtitle
            }
            Spacer(minLength: 4)
        }
        .contentShape(Rectangle())
    }

    private var windowCountText: String? {
        guard model.hasAccessibility, let windows = app.windows else { return nil }
        switch windows.count {
        case 0: return "No windows"
        case 1: return "1 window"
        default: return "\(windows.count) windows"
        }
    }

    private var stateText: String? {
        if app.info.isActive { return "Frontmost" }
        if app.info.isHidden { return "Hidden" }
        return nil
    }

    private var subtitleText: String {
        [stateText, windowCountText].compactMap { $0 }.joined(separator: " · ")
    }

    private var subtitle: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let state = stateText.map { Text($0).foregroundColor(app.info.isActive ? PanelStyle.accent(for: colorScheme) : style.secondaryInk) }
        let count = windowCountText.map { Text($0).foregroundColor(style.secondaryInk) }
        let separator = Text(" · ").foregroundColor(style.secondaryInk)
        let line: Text = switch (state, count) {
        case let (state?, count?): state + separator + count
        case let (state?, nil): state
        case let (nil, count?): count
        case (nil, nil): Text("Running").foregroundColor(style.secondaryInk)
        }
        return line.font(.system(size: 11)).lineLimit(1)
    }

    @ViewBuilder private var windowList: some View {
        let style = PanelStyle.colors(for: colorScheme)
        VStack(alignment: .leading, spacing: 1) {
            if !model.hasAccessibility {
                AccessibilityGrantRow(request: model.requestAccessibility)
            } else if let windows = app.windows {
                if windows.isEmpty {
                    Text("No open windows").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                        .padding(.vertical, 4).padding(.leading, 8)
                } else {
                    ForEach(windows) { window in
                        WindowRowView(window: window, model: model)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Reading windows…").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                }
                .padding(.vertical, 4).padding(.leading, 8)
            }
        }
        .padding(.leading, 17)
    }
}

/// A window under its app: click it to bring it forward; minimise (or restore) and close beside it.
private struct WindowRowView: View {
    let window: WindowsWindowRow
    @ObservedObject var model: WindowsPanelModel

    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        HStack(spacing: 5) {
            Button {
                model.bringForward(window)
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: window.isMinimised ? "minus.rectangle" : "macwindow")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(style.secondaryInk)
                        .frame(width: 16)
                    Text(window.title).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(window.isMinimised ? style.secondaryInk : style.inkOnTrack)
                    if window.isMinimised {
                        Text("Minimised")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(style.secondaryInk)
                            .padding(.horizontal, 6).padding(.vertical, 1.5)
                            .background(Capsule().fill(style.controlFill))
                            .fixedSize()
                    }
                    Spacer(minLength: 4)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Bring “\(window.title)” forward")
            .accessibilityLabel("\(window.title)\(window.isMinimised ? ", minimised" : "")")
            .accessibilityHint("Brings the window forward")

            PanelRoundButton(systemImage: window.isMinimised ? "arrow.up.left.and.arrow.down.right" : "minus", size: 22) {
                model.toggleMinimised(window)
            }
            .help(window.isMinimised ? "Restore" : "Minimise")
            .accessibilityLabel(window.isMinimised ? "Restore \(window.title)" : "Minimise \(window.title)")
            PanelRoundButton(systemImage: "xmark", size: 22) { model.close(window) }
                .help("Close")
                .accessibilityLabel("Close \(window.title)")
        }
        .padding(.vertical, 2).padding(.leading, 6).padding(.trailing, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hovering ? style.controlFill : Color.clear))
        .onHover { hovering = $0 }
    }
}

/// Shown in place of the window list while Accessibility is missing.
private struct AccessibilityGrantRow: View {
    let request: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        HStack(spacing: 8) {
            Image(systemName: "lock.shield")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(PanelStyle.accent(for: colorScheme))
            VStack(alignment: .leading, spacing: 1) {
                Text("Windows need Accessibility").font(.system(size: 12, weight: .semibold))
                Text("To list, bring forward, minimise and close them.")
                    .font(.system(size: 11)).foregroundStyle(style.secondaryInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            PanelCapsuleButton(title: "Allow…", kind: .accent, action: request)
        }
        .padding(.vertical, 4).padding(.horizontal, 6)
    }
}

/// "Force quit Safari? Unsaved changes are lost." with Cancel and Force Quit.
private struct ForceQuitConfirmation: View {
    let name: String
    let cancel: () -> Void
    let confirm: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
            Text("Force quit \(name)? Unsaved changes are lost.")
                .font(.system(size: 11.5))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            PanelCapsuleButton(title: "Cancel", kind: .plain, action: cancel)
            PanelCapsuleButton(title: "Force Quit", kind: .destructive, action: confirm)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.12)))
    }
}

/// A small capsule text button for tiles (Allow…, Cancel, Force Quit).
struct PanelCapsuleButton: View {
    enum Kind { case plain, accent, destructive }

    let title: String
    var kind: Kind = .plain
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        Button(action: action) {
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(kind == .plain ? style.inkOnTrack : Color.white)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(Capsule().fill(fill(style)))
                .contentShape(Capsule())
                .fixedSize()
        }
        .buttonStyle(.plain)
    }

    private func fill(_ style: PanelStyle) -> Color {
        switch kind {
        case .plain: style.trackFill
        case .accent: OrbitTheme.accent
        case .destructive: Color(red: 0.86, green: 0.24, blue: 0.22)
        }
    }
}

/// An app's icon, or a generic app glyph when there is none.
struct AppIconImage: View {
    let icon: NSImage?
    let size: CGFloat

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "app.dashed").resizable().aspectRatio(contentMode: .fit).foregroundStyle(.secondary)
                    .padding(size * 0.12)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
