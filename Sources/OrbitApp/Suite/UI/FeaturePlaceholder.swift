import OrbitCore
import SwiftUI

/// The panel tab a feature stub shows until its real implementation lands.
struct FeaturePlaceholderPanel: View {
    let feature: FeatureID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader(feature.title)
            PanelTile {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: feature.symbol).font(.system(size: 18)).foregroundStyle(OrbitTheme.accent)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Coming in this build").font(.system(size: 13, weight: .semibold))
                        Text(feature.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

/// The settings page content a feature stub shows until its real implementation lands.
struct FeaturePlaceholderSettings: View {
    let feature: FeatureID

    var body: some View {
        SettingsSection("Settings") {
            Text("\(feature.title) settings arrive with the feature in this build.")
                .foregroundStyle(.secondary)
        }
    }
}
