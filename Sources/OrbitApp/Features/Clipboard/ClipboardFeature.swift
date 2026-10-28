import OrbitCore
import SwiftUI

/// Clipboard (spec §5.5). PLACEHOLDER from the suite shell so the app runs: the Clipboard task replaces this
/// file wholesale with the real feature, keeping the class name and `init(context:)`. The contract is in
/// `Suite/SuiteFeature.swift`.
@MainActor
final class ClipboardFeature: SuiteFeature {
    let id = FeatureID.clipboard
    private let context: SuiteContext
    private var isRunning = false

    init(context: SuiteContext) {
        self.context = context
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
    }

    func makePanelView() -> AnyView { AnyView(FeaturePlaceholderPanel(feature: id)) }

    func makeSettingsView() -> AnyView { AnyView(FeaturePlaceholderSettings(feature: id)) }

    static func snapshotViews() -> FeatureSnapshotViews {
        FeatureSnapshotViews(panel: FeaturePlaceholderPanel(feature: .clipboard), settings: FeaturePlaceholderSettings(feature: .clipboard))
    }
}
