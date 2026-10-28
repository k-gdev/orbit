import OrbitCore
import SwiftUI

/// The panel tab a feature stub shows until its real implementation lands.
struct FeaturePlaceholderPanel: View {
    let feature: FeatureID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(feature.title.uppercased())
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: feature.symbol).font(.system(size: 18)).foregroundStyle(OrbitTheme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Coming in this build").font(.system(size: 13, weight: .semibold))
                    Text(feature.summary).font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.6)))
        }
    }
}

/// The settings page content a feature stub shows until its real implementation lands.
struct FeaturePlaceholderSettings: View {
    let feature: FeatureID

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.headline)
            Text("\(feature.title) settings arrive with the feature in this build.")
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        }
    }
}
