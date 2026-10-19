import AppKit
import Combine
import OrbitCore
import SwiftUI
import UniformTypeIdentifiers

/// Reads the fields to show for a file. Images use `ImageMetadata.read`; audio gets its own loader from `EditorRouter`.
typealias MetadataLoader = @Sendable (URL) -> [MetadataField]

/// State of the Metadata editor: the fields read from the file, the text typed into the editable ones, and (audio) a new artwork.
@MainActor
final class MetadataModel: ObservableObject {
    /// The key the job reads the artwork's file path from.
    static let artworkKey = "artwork"

    @Published private(set) var fields: [MetadataField] = []
    @Published private(set) var loaded = false
    @Published var drafts: [MetadataKey: String] = [:]
    @Published var artwork: URL?

    /// Whether the editor offers an artwork well (audio files).
    let allowsArtwork: Bool
    private let loader: MetadataLoader

    init(allowsArtwork: Bool, loader: @escaping MetadataLoader) {
        self.allowsArtwork = allowsArtwork
        self.loader = loader
    }

    /// Reads the fields now. The router calls this before the panel opens: the panel is sized once, from its content, so the
    /// fields must be there when it is measured.
    func load(_ url: URL) { set(fields: loader(url)) }

    func set(fields: [MetadataField]) {
        self.fields = fields
        drafts = Dictionary(uniqueKeysWithValues: fields.filter(\.editable).map { ($0.key, $0.value) })
        loaded = true
    }

    /// Only what the person changed, keyed by `MetadataKey.rawValue` (an empty value removes the field), plus the artwork's path.
    var edits: [String: String] {
        var result: [String: String] = [:]
        for field in fields where field.editable {
            let draft = (drafts[field.key] ?? field.value).trimmingCharacters(in: .whitespacesAndNewlines)
            if draft != field.value { result[field.key.rawValue] = draft }
        }
        if let artwork { result[Self.artworkKey] = artwork.path }
        return result
    }

    /// The photo's position, when the file has one.
    var coordinate: (latitude: Double, longitude: Double)? {
        guard let lat = fields.first(where: { $0.key == .gpsLatitude }).flatMap({ Double($0.value) }),
              let lon = fields.first(where: { $0.key == .gpsLongitude }).flatMap({ Double($0.value) }) else { return nil }
        return (lat, lon)
    }

    func chooseArtwork() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.jpeg, .png]
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK { artwork = panel.url }
    }
}

struct MetadataEditor: View {
    static let width: CGFloat = 460

    let title: String
    @ObservedObject var model: MetadataModel
    let onClose: () -> Void
    let onApply: ([String: String]) -> Void
    /// Saves a copy without the location (the existing strip-location tool); other edits are not part of it.
    let onRemoveLocation: () -> Void

    @Environment(\.glassRendering) private var rendering

    var body: some View {
        EditorShell(title: title, applyTitle: "Save", canApply: !model.edits.isEmpty, onClose: onClose,
                    onApply: { onApply(model.edits) }) {
            VStack(spacing: 10) {
                if model.allowsArtwork { artworkWell }
                content
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if !model.loaded {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, minHeight: 80)
        } else if model.fields.isEmpty {
            Text("No metadata found").font(.system(size: 13)).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 80)
        } else {
            if rendering == .live {
                // A scroll view has no height of its own, and the panel is measured once, so give it one.
                ScrollView { rows }.frame(height: min(rowsHeight, Self.maxRowsHeight))
            } else {
                rows // snapshots: `ImageRenderer` does not draw scroll views
            }
        }
    }

    private static let maxRowsHeight: CGFloat = 340

    /// What `rows` needs: 34 pt per field row, and the location row (two lines) when there is one.
    private var rowsHeight: CGFloat {
        let plain = model.fields.filter { $0.key != .gpsLatitude && $0.key != .gpsLongitude }.count
        return CGFloat(plain) * 34 + (model.coordinate == nil ? 0 : 64)
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(model.fields.filter { $0.key != .gpsLatitude && $0.key != .gpsLongitude }, id: \.self) { row($0) }
            location
        }
    }

    private func row(_ field: MetadataField) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(field.label).font(.system(size: 13)).foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            if field.editable {
                EditorTextField(placeholder: field.label, text: Binding(get: { model.drafts[field.key] ?? field.value },
                                                                        set: { model.drafts[field.key] = $0 }))
            } else {
                Text(field.value).font(.system(size: 13)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// The GPS position (read only) with its two actions.
    @ViewBuilder
    private var location: some View {
        if let place = model.coordinate {
            HStack(alignment: .center, spacing: 12) {
                Text("Location").font(.system(size: 13)).foregroundStyle(.secondary).frame(width: 104, alignment: .trailing)
                VStack(alignment: .leading, spacing: 6) {
                    Text(String(format: "%.5f, %.5f", place.latitude, place.longitude))
                        .font(.system(size: 13).monospacedDigit()).textSelection(.enabled)
                    HStack(spacing: 6) {
                        ChoiceChip(title: "Open in Maps", selected: false) {
                            NSWorkspace.shared.open(ImageMetadata.mapLink(lat: place.latitude, lon: place.longitude))
                        }
                        ChoiceChip(title: "Remove location", selected: false, action: onRemoveLocation)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var artworkWell: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.08))
                if let url = model.artwork, rendering == .live, let image = NSImage(contentsOf: url) {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: model.artwork == nil ? "photo.badge.plus" : "photo").font(.system(size: 22))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { model.chooseArtwork() }
            VStack(alignment: .leading, spacing: 6) {
                Text("Artwork").font(.system(size: 14, weight: .medium))
                HStack(spacing: 6) {
                    ChoiceChip(title: model.artwork == nil ? "Choose image…" : "Change…", selected: false) { model.chooseArtwork() }
                    if model.artwork != nil { ChoiceChip(title: "Clear", selected: false) { model.artwork = nil } }
                }
                Text(model.artwork?.lastPathComponent ?? "JPEG or PNG").font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}
