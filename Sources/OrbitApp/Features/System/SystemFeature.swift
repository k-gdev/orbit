import OrbitCore
import SwiftUI

/// System (spec §5.2). PLACEHOLDER from the suite shell so the app runs: the System task replaces this
/// file wholesale with the real feature, keeping the class name and `init(context:)`. The contract is in
/// `Suite/SuiteFeature.swift`.
@MainActor
final class SystemFeature: SuiteFeature {
    let id = FeatureID.system
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
        FeatureSnapshotViews(panel: FeaturePlaceholderPanel(feature: .system), settings: FeaturePlaceholderSettings(feature: .system))
    }
}
