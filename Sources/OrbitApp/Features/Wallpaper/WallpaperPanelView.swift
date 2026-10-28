import OrbitCore
import SwiftUI

/// The Wallpaper tab: one card per connected display with a preview, what it plays and whether it is playing, and a
/// Choose… menu (a video file, a downloaded aerial, or none). A note at the end says where aerials come from.
struct WallpaperPanelView: View {
    @ObservedObject var model: WallpaperModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Displays")
            if model.connectedDisplays.isEmpty {
                PanelTile {
                    Text("No displays found.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            ForEach(model.connectedDisplays) { display in
                WallpaperDisplayTile(model: model, display: display)
            }
            WallpaperAerialsNote(model: model)
                .padding(.top, 2)
        }
    }
}

/// One display's card.
struct WallpaperDisplayTile: View {
    @ObservedObject var model: WallpaperModel
    let display: WallpaperDisplayItem

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let source = model.source(for: display)
        let status = model.status(for: display)
        PanelTile {
            HStack(alignment: .center, spacing: 11) {
                WallpaperPreview(image: source.flatMap(model.thumbnail(for:)), source: source, status: status)
                    .frame(width: 104, height: 58.5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .center, spacing: 6) {
                        Text(display.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 4)
                        PanelMenuButton(title: "Choose…", maxWidth: 110) {
                            WallpaperChooseMenu(model: model, display: display)
                        }
                    }
                    Text(source.map(model.title(for:)) ?? "No wallpaper")
                        .font(.system(size: 12))
                        .foregroundStyle(source == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .lineLimit(1).truncationMode(.tail)
                    WallpaperStatusLine(status: status, kind: source.map(model.kind(of:)))
                }
            }
        }
    }
}

/// "● Playing · Aerial · Landscape", "Paused · Screen locked", "Shows your desktop picture".
struct WallpaperStatusLine: View {
    let status: WallpaperModel.Status
    let kind: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        HStack(spacing: 5) {
            switch status {
            case .playing:
                Circle().fill(PanelStyle.accent(for: colorScheme)).frame(width: 6, height: 6)
                Text(["Playing", kind].compactMap { $0 }.joined(separator: " · "))
            case .paused(let reason):
                Image(systemName: "pause.fill").font(.system(size: 8, weight: .bold))
                Text("Paused · \(reason.label)")
            case .starting:
                Circle().fill(style.secondaryInk.opacity(0.6)).frame(width: 6, height: 6)
                Text(["Starting", kind].compactMap { $0 }.joined(separator: " · "))
            case .off:
                Image(systemName: "moon.zzz").font(.system(size: 9, weight: .semibold))
                Text("Wallpaper is off")
            case .missing:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                Text("File not found")
            case .none:
                Text("Shows your desktop picture")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(style.secondaryInk)
        .lineLimit(1)
    }
}

/// The 16:9 preview: the wallpaper's thumbnail (dimmed with a pause badge while paused), or a placeholder.
struct WallpaperPreview: View {
    let image: NSImage?
    let source: WallpaperSource?
    let status: WallpaperModel.Status

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        ZStack {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    .saturation(isPaused ? 0.55 : 1)
            } else {
                shape.fill(style.trackFill)
                Image(systemName: placeholderSymbol)
                    .font(.system(size: 17, weight: .regular))
                    .foregroundStyle(style.secondaryInk.opacity(0.75))
            }
            if isPaused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(shape.strokeBorder(style.tileStroke, lineWidth: 0.5))
    }

    private var isPaused: Bool {
        if case .paused = status { return true }
        return false
    }

    private var placeholderSymbol: String {
        switch source {
        case nil: "photo.on.rectangle"
        case .aerial?: status == .missing ? "exclamationmark.triangle" : "sparkles.tv"
        case .video?: status == .missing ? "exclamationmark.triangle" : "film"
        }
    }
}

/// The Choose… menu's items: a video file, videos already used on other displays, each downloaded aerial by
/// category, and None. The current choice has a check mark.
struct WallpaperChooseMenu: View {
    @ObservedObject var model: WallpaperModel
    let display: WallpaperDisplayItem

    var body: some View {
        let current = model.source(for: display)
        Button("Video File…") { model.chooseVideoFile(display) }
        let videos = model.settings.assignments.videos
        if !videos.isEmpty {
            Section("Your Videos") {
                ForEach(videos, id: \.identity) { video in
                    item(model.title(for: video), source: video, current: current)
                }
            }
        }
        if model.aerials.isEmpty {
            Section("Apple Aerials") {
                Button("None Downloaded") {}.disabled(true)
                Button("Open Wallpaper Settings…") { model.openWallpaperSettings() }
            }
        } else {
            ForEach(model.aerialGroups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.aerials) { aerial in
                        item(aerial.name, source: .aerial(id: aerial.id), current: current)
                    }
                }
            }
        }
        Divider()
        Toggle("None", isOn: Binding(get: { current == nil }, set: { on in if on { model.assign(nil, to: display) } }))
    }

    private func item(_ title: String, source: WallpaperSource, current: WallpaperSource?) -> some View {
        Toggle(title, isOn: Binding(get: { current?.identity == source.identity },
                                    set: { on in if on { model.assign(source, to: display) } }))
    }
}

/// Where the aerials come from, with a link to download more in System Settings.
struct WallpaperAerialsNote: View {
    @ObservedObject var model: WallpaperModel

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let count = model.aerials.count
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "sparkles.tv").font(.system(size: 10, weight: .medium))
            Text(count == 0 ? "No Apple aerials downloaded yet."
                            : "\(count) Apple aerial\(count == 1 ? "" : "s") downloaded on this Mac.")
                .lineLimit(1)
            Spacer(minLength: 6)
            PanelLinkButton("Get more") { model.openWallpaperSettings() }
        }
        .font(.system(size: 11))
        .foregroundStyle(PanelStyle.colors(for: colorScheme).secondaryInk)
        .padding(.horizontal, 4)
    }
}
