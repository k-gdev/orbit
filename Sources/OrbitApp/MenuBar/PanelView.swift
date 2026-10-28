import OrbitCore
import SwiftUI

/// What the panel's footer does. Supplied by `StatusItemController` (no-ops in snapshots).
struct PanelActions {
    var openSettings: () -> Void = {}
    var openFeaturesPage: () -> Void = {}
    var quit: () -> Void = {}
    var openFiles: () -> Void = {}
    var about: () -> Void = {}
    /// The "Recent results" submenu, read each time the panel's body is built.
    var recents: () -> [(id: UUID, title: String)] = { [] }
    var openRecent: (UUID) -> Void = { _ in }
}

/// The panel's state: which tabs show, which one is selected, and the selected feature's view. Feature
/// views are built only for the visible tab and dropped when the panel closes (`clearPage`).
@MainActor
final class PanelModel: ObservableObject {
    @Published private(set) var tabs: [FeatureID] = []
    @Published private(set) var selected: FeatureID?
    @Published private(set) var page: AnyView?
    @Published private(set) var pageScrollsItself = false
    /// The tallest the content area may be before it scrolls (derived from the screen).
    @Published var contentMaxHeight: CGFloat = 560

    /// Builds the selected feature's panel view (and says whether it scrolls itself).
    var pageProvider: (FeatureID) -> (view: AnyView, scrollsItself: Bool) = { _ in (AnyView(EmptyView()), false) }
    /// Called after the selection changes, with the previous and new tab.
    var onSelectionChange: (_ old: FeatureID?, _ new: FeatureID?) -> Void = { _, _ in }

    /// Sets the tabs, keeping the selection when it is still among them, else `preferred`, else the first.
    func update(tabs newTabs: [FeatureID], preferred: FeatureID?) {
        if newTabs != tabs { tabs = newTabs }
        let keep = selected.flatMap { newTabs.contains($0) ? $0 : nil }
        let next = keep ?? preferred.flatMap { newTabs.contains($0) ? $0 : nil } ?? newTabs.first
        if next != selected || (page == nil && next != nil) { show(next) }
    }

    /// Selects a tab (from a click in the tab row).
    func select(_ id: FeatureID) {
        guard tabs.contains(id), id != selected else { return }
        show(id)
    }

    /// Releases the feature view (the panel is closed).
    func clearPage() {
        page = nil
    }

    private func show(_ id: FeatureID?) {
        let old = selected
        selected = id
        if let id {
            let built = pageProvider(id)
            page = built.view
            pageScrollsItself = built.scrollsItself
        } else {
            page = nil
            pageScrollsItself = false
        }
        if old != id { onSelectionChange(old, id) }
    }
}

/// The menu bar panel: tabs across the top (one per enabled feature), the selected feature's content
/// (scrolling past `contentMaxHeight`), and a footer with Settings…, Quit Orbit and a … menu holding the
/// app's other commands. 390 pt wide on Orbit's glass.
struct PanelView: View {
    @ObservedObject var model: PanelModel
    @ObservedObject var settings: SettingsStore
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            if !model.tabs.isEmpty {
                PanelTabRow(tabs: model.tabs, selected: model.selected) { model.select($0) }
                    .padding(.horizontal, 8)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
            }
            content
            PanelFooter(settings: settings, actions: actions)
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.top, 8)
                .padding(.bottom, PanelMetrics.inset)
        }
        .padding(.top, model.tabs.isEmpty ? PanelMetrics.inset : 0)
        .frame(width: PanelMetrics.width)
        .background(GlassBackground(shape: RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous),
                                    tintOpacity: colorScheme == .dark ? 0.10 : 0.30))
        .environment(\.panelContentMaxHeight, model.contentMaxHeight)
    }

    @ViewBuilder private var content: some View {
        if let page = model.page {
            if model.pageScrollsItself {
                page
                    .frame(width: PanelMetrics.contentWidth)
                    .frame(maxHeight: model.contentMaxHeight)
                    .padding(.horizontal, PanelMetrics.inset)
            } else {
                PanelScrollArea(maxHeight: model.contentMaxHeight) {
                    page.frame(width: PanelMetrics.contentWidth)
                }
            }
        } else if model.tabs.isEmpty {
            PanelEmptyState(openFeatures: actions.openFeaturesPage)
                .padding(.horizontal, PanelMetrics.inset)
        }
    }
}

/// Lays its content out at its natural height, up to `maxHeight`, and scrolls beyond that.
private struct PanelScrollArea<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder var content: () -> Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView(.vertical) {
            content()
                .padding(.horizontal, PanelMetrics.inset)
                .padding(.vertical, 1)
                .background(GeometryReader { geo in
                    Color.clear.preference(key: PanelContentHeightKey.self, value: geo.size.height)
                })
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(contentHeight > maxHeight ? .automatic : .never)
        .frame(height: min(max(contentHeight, 1), maxHeight))
        .onPreferenceChange(PanelContentHeightKey.self) { contentHeight = $0 }
    }
}

private struct PanelContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

/// The row of feature tabs: icon over a small label, the selected one on a white pill.
private struct PanelTabRow: View {
    let tabs: [FeatureID]
    let selected: FeatureID?
    let select: (FeatureID) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let dark = colorScheme == .dark
        HStack(spacing: 1) {
            ForEach(tabs, id: \.self) { id in
                let isOn = id == selected
                Button { select(id) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: id.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(height: 17)
                        Text(id.title)
                            .font(.system(size: 10, weight: isOn ? .semibold : .medium))
                            .tracking(-0.2)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(isOn ? OrbitTheme.accent : PanelStyle.colors(for: colorScheme).secondaryInk)
                    .padding(.top, 7).padding(.bottom, 6)
                    .frame(maxWidth: .infinity)
                    .background {
                        if isOn {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(dark ? Color.white.opacity(0.16) : Color.white)
                                .shadow(color: .black.opacity(dark ? 0 : 0.10), radius: 1, y: 1)
                        }
                    }
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .help(id.title)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(dark ? Color.white.opacity(0.06) : Color.black.opacity(0.05)))
    }
}

/// Settings…, Quit Orbit, and a … menu with the commands the old menu bar menu had.
private struct PanelFooter: View {
    @ObservedObject var settings: SettingsStore
    let actions: PanelActions

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        HStack(spacing: 8) {
            Button(action: actions.openSettings) { footerLabel("Settings…", systemImage: "gearshape", style: style) }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
            Button(action: actions.quit) { footerLabel("Quit Orbit", systemImage: "power", style: style) }
                .buttonStyle(.plain)
                .keyboardShortcut("q", modifiers: .command)
            Menu {
                Button("Open Files…", action: actions.openFiles)
                Toggle("Wheel enabled", isOn: $settings.isEnabled)
                Menu("Recent results") {
                    let recents = actions.recents()
                    if recents.isEmpty {
                        Text("No recent results")
                    } else {
                        ForEach(recents, id: \.id) { entry in
                            Button(entry.title) { actions.openRecent(entry.id) }
                        }
                    }
                }
                Divider()
                Button("About Orbit", action: actions.about)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(style.inkOnTrack)
                    .frame(width: 34, height: 30)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tileFill))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tileStroke, lineWidth: 0.5))
                    .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
    }

    private func footerLabel(_ title: String, systemImage: String, style: PanelStyle) -> some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .medium))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(style.inkOnTrack)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(style.tileFill))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(style.tileStroke, lineWidth: 0.5))
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Shown when every feature is off.
private struct PanelEmptyState: View {
    let openFeatures: () -> Void

    var body: some View {
        PanelTile(spacing: 8, padding: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.2x2").font(.system(size: 20)).foregroundStyle(OrbitTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No features are on").font(.system(size: 13, weight: .semibold))
                    Text("Turn on features in Settings → Features.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            Button("Open Features…", action: openFeatures)
                .controlSize(.small)
        }
    }
}
