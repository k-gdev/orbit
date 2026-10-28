import AppKit
import OrbitCore
import SwiftUI

extension ClipboardItem {
    /// The SF Symbol for the entry's kind (a lock for a copied password).
    var kindSymbol: String {
        if concealed { return "lock.fill" }
        return switch kind {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }

    /// "Safari · 2 min ago", with "Password" after the app for a copied password, the size added for
    /// images and `fileLabel` ("Missing") at the end for a files entry whose files are gone.
    func metaText(now: Date, fileLabel: String? = nil) -> String {
        var parts: [String] = []
        if let sourceName, !sourceName.isEmpty { parts.append(sourceName) }
        if concealed { parts.append("Password") }
        parts.append(Self.ageLabel(for: date, now: now))
        if kind == .image && !concealed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(byteSize), countStyle: .file)) }
        if let fileLabel { parts.append(fileLabel) }
        return parts.joined(separator: " · ")
    }
}

/// The square at the left of a row: the image's thumbnail for pictures, the kind's symbol otherwise.
struct ClipboardKindBadge: View {
    let item: ClipboardItem
    @ObservedObject var model: ClipboardModel
    var size: CGFloat = 34

    @State private var loaded: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.26, style: .continuous).fill(style.trackFill)
            if let image = loaded ?? model.cachedThumbnail(for: item) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous))
            } else {
                Image(systemName: item.kindSymbol)
                    .font(.system(size: size * 0.4, weight: .medium))
                    .foregroundStyle(style.inkOnTrack)
            }
        }
        .frame(width: size, height: size)
        .task(id: item.id) {
            guard item.kind == .image, loaded == nil, model.cachedThumbnail(for: item) == nil else { return }
            loaded = await model.thumbnail(for: item)
        }
    }
}

/// "[app icon] Safari · 2 min ago" (and "Missing" when a files entry's files are gone).
struct ClipboardMetaLine: View {
    let item: ClipboardItem
    @ObservedObject var model: ClipboardModel
    let now: Date

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            if let id = item.sourceBundleID, let icon = AppLookup.icon(forBundleID: id) {
                Image(nsImage: icon).resizable().frame(width: 12, height: 12)
            }
            Text(item.metaText(now: now, fileLabel: model.fileStatuses[item.id]?.metaLabel))
                .font(.system(size: 10.5))
                .foregroundStyle(PanelStyle.colors(for: colorScheme).secondaryInk)
                .lineLimit(1)
        }
    }
}
