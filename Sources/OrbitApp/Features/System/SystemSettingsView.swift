import OrbitCore
import SwiftUI

/// System's Settings page: the menu bar readout and how the panel tab shows and refreshes its numbers.
struct SystemSettingsView: View {
    @ObservedObject var settings: SystemSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Menu bar", footnote: "The readout sits beside Orbit's icon and refreshes every 2 seconds. "
                            + "With it off, System measures nothing until you open its tab.") {
                Picker("Readout", selection: $settings.menuBarReadout) {
                    ForEach(MenuBarReadout.allCases, id: \.self) { readout in
                        Text(readout.title).tag(readout)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsSection("Panel", footnote: "Numbers refresh only while the System tab is open.") {
                Toggle("Show each CPU cluster", isOn: $settings.showPerCluster)
                Picker("Refresh every", selection: $settings.sampleInterval) {
                    ForEach(SystemSettings.intervalChoices, id: \.self) { seconds in
                        Text(seconds == 1 ? "1 second" : "\(Int(seconds)) seconds").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                .fixedSize()
            }
            SettingsSection("Sensors") {
                Text("Temperatures come from the chip's own sensors (the SMC and IOHID), batteries from macOS power "
                     + "sources, including Bluetooth accessories such as AirPods. Nothing needs a permission.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
