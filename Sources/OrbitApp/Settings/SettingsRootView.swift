import AppKit
import OrbitCore
import SwiftUI

/// The page the Settings window shows; `SettingsWindowController.show(page:)` sets it.
@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var page: SettingsPage

    init(page: SettingsPage = .general) { self.page = page }
}

/// Everything the Settings window reads and calls. The app builds it over the live registry; the
/// snapshot CLI over throwaway settings and fixture views.
struct SettingsDependencies {
    let settings: SettingsStore
    let suite: SuiteSettings
    let permissions: PermissionCenter
    /// Turns a feature on or off (`FeatureRegistry.setEnabled`).
    var setEnabled: (FeatureID, Bool) -> Void
    /// A feature's own settings view (`makeSettingsView()`, or `snapshotViews().settings`).
    var featureSettings: (FeatureID) -> AnyView
    var capabilities: Capabilities
    var rescan: () -> Capabilities
    var showWelcome: () -> Void
}

/// The Settings window: a side rail (General, Wheel, Features, one page per feature, About) and the
/// selected page. 760 × 560 by default; the window uses a full-size content view with a transparent
/// title bar, so the rail runs to the top edge.
struct SettingsRootView: View {
    @ObservedObject var navigation: SettingsNavigation
    @ObservedObject var suite: SuiteSettings
    let dependencies: SettingsDependencies

    static let defaultSize = CGSize(width: 760, height: 560)

    init(navigation: SettingsNavigation, dependencies: SettingsDependencies) {
        self.navigation = navigation
        self.suite = dependencies.suite
        self.dependencies = dependencies
    }

    var body: some View {
        // A plain sidebar list beside the page rather than NavigationSplitView: macOS 26 draws that
        // sidebar as floating glass, which offscreen snapshots can't capture, and this rail needs no
        // collapsing. The top inset clears the window's traffic lights (full-size content view).
        HStack(spacing: 0) {
            List(selection: selection) {
                Section {
                    ForEach([SettingsPage.general, .wheel, .features], id: \.self) { railRow($0) }
                }
                Section("Features") {
                    ForEach(FeatureID.allCases, id: \.self) { railRow(.feature($0)) }
                }
                Section {
                    railRow(.about)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .padding(.top, Self.titlebarInset)
            .frame(width: Self.railWidth)
            .background(.regularMaterial)
            Divider()
            page(navigation.page)
                .id(navigation.page)
                .padding(.top, Self.titlebarInset - 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 640, minHeight: 420)
        .ignoresSafeArea(.container, edges: .top)
    }

    static let railWidth: CGFloat = 200
    static let titlebarInset: CGFloat = 30

    private var selection: Binding<SettingsPage?> {
        Binding(get: { navigation.page }, set: { if let page = $0 { navigation.page = page } })
    }

    private func railRow(_ page: SettingsPage) -> some View {
        HStack(spacing: 8) {
            Label(page.title, systemImage: page.symbol)
            Spacer(minLength: 0)
            if case .feature(let id) = page, !suite.isEnabled(id) {
                Text("Off").font(.caption).foregroundStyle(.secondary)
            }
        }
        .tag(page)
    }

    @ViewBuilder private func page(_ page: SettingsPage) -> some View {
        switch page {
        case .general:
            SettingsPageScroll(title: "General") {
                SettingsSection("General") {
                    GeneralSettingsRows(settings: dependencies.settings, showWelcome: dependencies.showWelcome)
                }
            }
        case .wheel:
            WheelPage(settings: dependencies.settings, capabilities: dependencies.capabilities, rescan: dependencies.rescan)
        case .features:
            FeaturesPage(suite: dependencies.suite, permissions: dependencies.permissions, setEnabled: dependencies.setEnabled)
        case .feature(let id):
            FeatureSettingsPage(feature: id, suite: dependencies.suite, permissions: dependencies.permissions,
                                setEnabled: dependencies.setEnabled, content: dependencies.featureSettings(id))
        case .about:
            AboutPage()
        }
    }
}

/// A Settings page: a large title over a scrolling column of `SettingsSection`s.
struct SettingsPageScroll<Content: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var content: () -> Content

    init(title: String, subtitle: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.system(size: 22, weight: .bold))
                    if let subtitle {
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content()
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Every wheel setting: on/off, then Triggers, Output, Copy & Move, Terminal and Helpers.
private struct WheelPage: View {
    @ObservedObject var settings: SettingsStore
    @State var capabilities: Capabilities
    let rescan: () -> Capabilities

    init(settings: SettingsStore, capabilities: Capabilities, rescan: @escaping () -> Capabilities) {
        self.settings = settings
        self._capabilities = State(initialValue: capabilities)
        self.rescan = rescan
    }

    var body: some View {
        SettingsPageScroll(title: "Wheel", subtitle: "Drag files in Finder and hold a modifier to convert them, run tools, or act on them.") {
            SettingsSection("Wheel") {
                Toggle("Enabled", isOn: $settings.isEnabled)
                Text("When off, holding the trigger modifiers during a drag does nothing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            WheelSettingsSections(settings: settings, capabilities: $capabilities, rescan: rescan)
        }
    }
}
