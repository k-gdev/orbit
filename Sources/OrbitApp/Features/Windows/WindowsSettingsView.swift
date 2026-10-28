import OrbitCore
import SwiftUI

/// Settings → Windows: the Dock preview (on/off, hover delay, what it can do with the permissions it has)
/// and whether minimised windows are listed. The shared header above already shows the permission rows.
struct WindowsSettingsView: View {
    @ObservedObject var settings: WindowsSettings
    @ObservedObject var permissions: PermissionCenter
    /// Whether the Windows feature itself is on (the readiness row must not say "Ready" while it is off).
    @ObservedObject var suite: SuiteSettings

    private var readiness: DockPreviewReadiness {
        DockPreviewReadiness(featureOn: suite.isEnabled(.windows),
                             enabled: settings.dockPreviewEnabled,
                             accessibility: permissions.status(.accessibility) == .granted,
                             screenRecording: permissions.status(.screenRecording) == .granted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Dock preview",
                            footnote: "Rest the pointer on an open app's icon in the Dock to see its windows. Click one to bring it forward.") {
                Toggle("Show window previews over the Dock", isOn: $settings.dockPreviewEnabled)
                HStack(spacing: 10) {
                    Text("Delay")
                    // Rounded to 0.05 s in the binding rather than with `step:`, which draws 31 tick marks.
                    Slider(value: Binding(get: { settings.previewDelay },
                                          set: { settings.previewDelay = ($0 / 0.05).rounded() * 0.05 }),
                           in: WindowsSettings.previewDelayRange)
                        .frame(maxWidth: 260)
                        .accessibilityLabel("Dock preview delay")
                        .accessibilityValue(delayText)
                    Text(delayText)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Spacer(minLength: 0)
                }
                .disabled(!settings.dockPreviewEnabled)
                statusRow
            }
            SettingsSection("Window lists",
                            footnote: "Applies to the Dock preview and to the Windows tab in the menu bar panel.") {
                Toggle("Show minimised windows", isOn: $settings.showMinimised)
            }
        }
    }

    private var delayText: String {
        settings.previewDelay < 0.01 ? "None" : String(format: "%.2f s", settings.previewDelay)
    }

    @ViewBuilder private var statusRow: some View {
        switch readiness {
        case .featureOff:
            Label("Not running: turn on Windows above to use the Dock preview.", systemImage: "moon.zzz")
                .font(.callout).foregroundStyle(.secondary)
        case .off:
            Label("Off. Orbit doesn't watch the Dock.", systemImage: "moon.zzz")
                .font(.callout).foregroundStyle(.secondary)
        case .needsAccessibility:
            HStack(spacing: 10) {
                Label("Needs Accessibility to see which Dock icon you're pointing at.", systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Allow…") { permissions.request(.accessibility) }
            }
        case .titlesOnly:
            HStack(spacing: 10) {
                Label("Without Screen Recording the preview shows window titles instead of thumbnails.",
                      systemImage: "rectangle.dashed")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Allow…") { permissions.request(.screenRecording) }
            }
        case .ready:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .font(.callout).foregroundStyle(.green)
        }
    }
}
