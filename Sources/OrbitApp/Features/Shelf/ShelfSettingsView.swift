import OrbitCore
import SwiftUI

/// The Shelf page of Settings (under the shared title, on/off switch and permission rows).
struct ShelfSettingsView: View {
    @ObservedObject var settings: ShelfSettings
    @ObservedObject var model: ShelfModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsSection("Opening", footnote: "The shelf also opens from the Shelf tab in the menu bar, and from the Shelf action in the wheel's Actions ring while this feature is on.") {
                Toggle("Open the shelf when I shake the cursor during a file drag", isOn: $settings.shakeToOpen)
                Text("Orbit only watches the mouse while a drag carries files, and reads nothing else. It needs no permission.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Window") {
                Toggle("Keep the shelf above other windows", isOn: $settings.keepOnTop)
                Text("The shelf shows on every Space and remembers its size and place on each display.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SettingsSection("Files", footnote: "The shelf holds references to your files, not copies. Dragging one out moves or copies it where you drop it, the way Finder would. Clearing the shelf never touches the files.") {
                HStack {
                    Text(model.urls.isEmpty ? "Nothing is on the shelf." : "\(ShelfStripView.countText(model.urls.count, offline: model.unreachable.count)) on the shelf")
                    Spacer()
                    Button("Clear Shelf") { model.clear() }
                        .disabled(model.urls.isEmpty)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
