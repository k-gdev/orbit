import AppKit
import OrbitCore
import SwiftUI

/// Settings → Features: one card per feature with its on/off switch, what it does, and the permissions
/// it uses with their live status and a button to the right System Settings pane.
struct FeaturesPage: View {
    @ObservedObject var suite: SuiteSettings
    @ObservedObject var permissions: PermissionCenter
    let setEnabled: (FeatureID, Bool) -> Void

    var body: some View {
        SettingsPageScroll(title: "Features",
                           subtitle: "Turn each part of Orbit on or off. A feature that is off does no work and asks for nothing; turning one on asks for the permissions it needs.") {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(FeatureID.allCases, id: \.self) { id in
                    FeatureCard(feature: id, suite: suite, permissions: permissions, setEnabled: setEnabled)
                }
            }
        }
        .onAppear { permissions.refresh() }
    }
}

/// A feature's icon, title, summary and switch, then its permission rows. Used on the Features page and
/// as the header of each feature's own page.
struct FeatureCard: View {
    let feature: FeatureID
    @ObservedObject var suite: SuiteSettings
    @ObservedObject var permissions: PermissionCenter
    let setEnabled: (FeatureID, Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                FeatureIcon(feature: feature, isOn: suite.isEnabled(feature))
                VStack(alignment: .leading, spacing: 2) {
                    Text(feature.title).font(.system(size: 13, weight: .semibold))
                    Text(feature.summary).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = feature.unavailableReason {
                        Label(reason, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 8)
                Toggle(feature.title, isOn: Binding(get: { suite.isEnabled(feature) },
                                                    set: { setEnabled(feature, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            if !feature.permissions.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(feature.permissions, id: \.permission) { use in
                        PermissionRow(use: use, status: permissions.status(use.permission)) {
                            permissions.openSettings(use.permission)
                        }
                    }
                }
                .padding(.leading, 40)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
    }
}

/// The feature's symbol on a rounded square: accent when on, grey when off.
struct FeatureIcon: View {
    let feature: FeatureID
    let isOn: Bool

    var body: some View {
        Image(systemName: feature.symbol)
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isOn ? OrbitTheme.accent : Color.gray.opacity(0.55)))
    }
}

/// One permission a feature uses: its name and purpose, the live status, and Open System Settings.
struct PermissionRow: View {
    let use: PermissionUse
    let status: PermissionStatus
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(use.permission.title).font(.system(size: 12, weight: .medium))
                    if !use.requestOnEnable {
                        Text("Optional").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                }
                Text(use.purpose).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PermissionBadge(status: status)
            Button("Open System Settings", action: openSettings)
                .controlSize(.small)
        }
    }
}

/// Granted / Not granted / Unknown, with a matching symbol.
struct PermissionBadge: View {
    let status: PermissionStatus

    var body: some View {
        switch status {
        case .granted:
            Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(Color.green).font(.caption)
        case .notGranted:
            Label("Not granted", systemImage: "xmark.circle").foregroundStyle(.secondary).font(.caption)
        case .unknown:
            Label("Unknown", systemImage: "questionmark.circle").foregroundStyle(.secondary).font(.caption)
                .help("macOS doesn't report this permission's status here; check System Settings.")
        }
    }
}

extension FeatureID {
    /// Why the feature can't fully work on this Mac, or nil. Shown on its card.
    var unavailableReason: String? {
        switch self {
        case .sound:
            if #available(macOS 14.2, *) { return nil }
            return "Per-app volume and output need macOS 14.2 or later; the mic mute shortcut still works."
        default:
            return nil
        }
    }
}
