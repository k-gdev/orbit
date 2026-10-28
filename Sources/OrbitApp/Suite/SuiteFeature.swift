import OrbitCore
import SwiftUI

// MARK: - The feature contract
//
// Every Orbit Suite section (Sound, System, Displays, Windows, Clipboard, Shelf, Wallpaper, Controls)
// is one class conforming to `SuiteFeature`, living in `Sources/OrbitApp/Features/<Name>/`, with its pure
// logic and persisted settings in `Sources/OrbitCore/<Name>/`. `FeatureRegistry` creates one instance
// of each at launch with `init(context:)` and owns it for the app's lifetime.
//
// Lifecycle rules:
// - `init(context:)` must be cheap and do NO work: no timers, monitors, hot keys, status items, taps,
//   windows, file reads beyond loading settings, and never a permission prompt. A feature that is off
//   costs nothing.
// - `start()` is called when the feature is turned on (at launch if it was on, or from Settings →
//   Features). Begin the background work the feature needs while on (hot keys, monitors, menu bar
//   items, desktop windows). It must be idempotent: a second `start()` while running does nothing.
// - `stop()` is called when the feature is turned off and when Orbit quits (`applicationWillTerminate`
//   → `FeatureRegistry.stopAll()`). Release EVERYTHING `start()` and the panel created: invalidate
//   timers, remove event monitors, unregister hot keys (`context.hotKeys.unregister`), remove status
//   items, close windows, destroy audio taps, release power assertions, and restore any system state
//   Orbit changed. Idempotent too, and safe to call when never started.
// - `panelDidAppear()` / `panelDidDisappear()` bracket the time this feature's tab is visible in the
//   menu bar panel (opening/closing the panel and switching tabs both count). Do panel-only work, such
//   as sampling sensors or polling device lists, only in between.
// - `makePanelView()` / `makeSettingsView()` build fresh SwiftUI views each time the panel tab or the
//   Settings page is shown. Build them from the shared pieces in `Suite/UI/` (`PanelTile`,
//   `PanelSectionHeader`, `PillSlider`, `PanelMenuButton`, `PanelRoundButton`, `LevelBars`,
//   `KeyComboRecorder`) so the suite reads as one app. The panel puts the view in a scroll view sized
//   to the screen (see `managesOwnScrolling` to opt out) and supplies `\.panelContentMaxHeight`.
// - `snapshotViews()` returns the same panel and settings views over FIXTURE data, for
//   `Orbit --snapshot-panel <id>` / `--snapshot-settings-page <id>`: no hardware access, no
//   permissions, no real `UserDefaults` (use `UserDefaults(suiteName:)` throwaways), no file writes.
//
// Persisted data: `UserDefaults` keys prefixed with the feature's raw id (`sound.`, `displays.`, ...)
// through a `<Name>Settings: ObservableObject` in OrbitCore built on `context.defaults`; files under
// `context.directory(for: id)` (`~/Library/Application Support/Orbit/<Title>/`), created only when needed.

/// One Orbit Suite section. See the contract above.
@MainActor
protocol SuiteFeature: AnyObject {
    /// Which section this is. Constant for the instance's lifetime.
    var id: FeatureID { get }

    /// Called once by `FeatureRegistry`. Cheap, side-effect free: store the context, load settings.
    init(context: SuiteContext)

    /// The feature was turned on (at launch or from Settings → Features). Idempotent.
    func start()

    /// The feature was turned off, or Orbit is quitting: stop ALL work and release every resource. Idempotent.
    func stop()

    /// The panel opened on this feature's tab, or the user switched to it. Default: nothing.
    func panelDidAppear()

    /// The panel closed or the user switched to another tab. Default: nothing.
    func panelDidDisappear()

    /// The menu bar panel tab's content (below the tab row, above the footer), 366 pt wide.
    func makePanelView() -> AnyView

    /// The feature's own Settings page content, shown under the shared header (title, on/off toggle,
    /// permission rows) inside the page's scroll view. Lay it out as a `VStack(alignment: .leading,
    /// spacing: 18)` of `SettingsSection("Title") { ... }` blocks, like the General and Wheel pages.
    func makeSettingsView() -> AnyView

    /// When true the panel does not wrap `makePanelView()` in a scroll view: the view gets a frame of at
    /// most `\.panelContentMaxHeight` and scrolls itself (for example a pinned search field above a
    /// scrolling list). Default: false. Static so snapshots honour it too.
    static var managesOwnScrolling: Bool { get }

    /// The panel and settings views over fixture data, for the headless snapshot CLI.
    static func snapshotViews() -> FeatureSnapshotViews
}

extension SuiteFeature {
    func panelDidAppear() {}
    func panelDidDisappear() {}
    static var managesOwnScrolling: Bool { false }
}

/// What `SuiteFeature.snapshotViews()` returns: the panel tab content and the settings page content.
struct FeatureSnapshotViews {
    var panel: AnyView
    var settings: AnyView

    init(panel: some View, settings: some View) {
        self.panel = AnyView(panel)
        self.settings = AnyView(settings)
    }
}

/// Geometry shared by the menu bar panel and the views features put in it.
enum PanelMetrics {
    /// The panel's outer width.
    static let width: CGFloat = 390
    /// Horizontal inset of tiles and headers from the panel edge.
    static let inset: CGFloat = 12
    /// The width a feature's panel view is laid out at.
    static var contentWidth: CGFloat { width - 2 * inset }
    /// The panel's corner radius.
    static let cornerRadius: CGFloat = 18
}

private struct PanelContentMaxHeightKey: EnvironmentKey {
    static let defaultValue: CGFloat = 560
}

extension EnvironmentValues {
    /// The tallest the feature's panel content may be before it must scroll (derived from the screen).
    var panelContentMaxHeight: CGFloat {
        get { self[PanelContentMaxHeightKey.self] }
        set { self[PanelContentMaxHeightKey.self] = newValue }
    }
}
