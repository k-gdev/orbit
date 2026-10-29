import OrbitCore
import SwiftUI

/// One feature's Settings page: the same card as on the Features page (switch and permissions), a note
/// when the feature is off, then the feature's own settings (`makeSettingsView()`), which stay editable
/// while it is off.
struct FeatureSettingsPage: View {
    let feature: FeatureID
    @ObservedObject var suite: SuiteSettings
    @ObservedObject var permissions: PermissionCenter
    let setEnabled: (FeatureID, Bool) -> Void
    let content: AnyView

    var body: some View {
        SettingsPageScroll(title: feature.title) {
            FeatureCard(feature: feature, suite: suite, permissions: permissions, setEnabled: setEnabled)
            if !suite.isEnabled(feature) {
                Label("\(feature.title) is off. You can still change its settings; they apply when you turn it on.",
                      systemImage: "moon.zzz")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .onAppear { permissions.refresh() }
    }
}
