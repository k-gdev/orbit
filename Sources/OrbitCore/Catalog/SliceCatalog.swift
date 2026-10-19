import Foundation

public enum SliceCatalog {
    public static let maxSlices = 10

    public static func content(for items: [DroppedItem], wheel: WheelKind,
                               capabilities: Capabilities, settings: CatalogSettings) -> WheelContent {
        switch wheel {
        case .convert: return convertContent(items, capabilities)
        case .tools: return toolsContent(items, capabilities, settings)
        case .actions: return WheelContent(slices: capped(actionSlices(settings)), hubMessage: nil)
        }
    }

    /// Keeps the first `maxSlices - 1` and folds the rest into a final MORE slice.
    /// `moreID` defaults to "<wheel>.more", derived from the first slice's id.
    public static func capped(_ slices: [Slice], moreID: String? = nil) -> [Slice] {
        guard slices.count > maxSlices else { return slices }
        let id = moreID ?? "\(slices[0].id.split(separator: ".").first.map(String.init) ?? "wheel").more"
        let rest = capped(Array(slices[(maxSlices - 1)...]), moreID: id + ".more")
        let more = Slice(id: id, title: "MORE", symbol: "ellipsis.circle", children: rest)
        return Array(slices[..<(maxSlices - 1)]) + [more]
    }

    private static func ring(_ parentID: String, _ children: [Slice]) -> [Slice] {
        capped(children, moreID: parentID + ".more")
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }

    // MARK: Convert

    private static func convertContent(_ items: [DroppedItem], _ caps: Capabilities) -> WheelContent {
        let cant = WheelContent(slices: [], hubMessage: "Orbit can't convert this file type")
        guard let first = items.first else { return cant }
        let categories = Set(items.map(\.category))

        // A folder, or items of mixed categories, become one archive.
        if categories.count > 1 || first.category == .folder {
            return WheelContent(slices: archiveOutputs(), hubMessage: nil)
        }

        if let missing = items.first(where: { ConversionMatrix.readHelper(for: $0).map { !caps.has($0) } ?? false }),
           let helper = ConversionMatrix.readHelper(for: missing) {
            return WheelContent(slices: [], hubMessage: "Install \(helper.displayName) to convert \(missing.formatKey.uppercased())")
        }

        // Walk the category's table order once; omit a format only when every item already has it.
        let outputs = ConversionMatrix.table(for: first.category).filter { output in
            items.contains { !isSameFormat($0, output) }
                && items.allSatisfy { ConversionMatrix.outputHelper(for: $0, output: output).map(caps.has) ?? true }
        }
        guard !outputs.isEmpty else { return cant }
        let slices = outputs.map { output in
            Slice(id: "convert.\(output.rawValue)", title: output.label,
                  subtitle: ConversionMatrix.subtitle(for: first, output: output, itemCount: items.count),
                  symbol: symbol(for: output), action: .convert(output))
        }
        return WheelContent(slices: capped(slices), hubMessage: nil)
    }

    private static func isSameFormat(_ item: DroppedItem, _ output: OutputFormat) -> Bool {
        item.formatKey == output.rawValue
    }

    private static func archiveOutputs() -> [Slice] {
        [OutputFormat.zip, .tar, .tgz].map {
            Slice(id: "convert.\($0.rawValue)", title: $0.label, symbol: "doc.zipper", action: .convert($0))
        }
    }

    private static func symbol(for output: OutputFormat) -> String {
        switch output {
        case .jpg, .png, .heic, .webp, .tiff, .avif, .bmp, .gif, .ico: "photo"
        case .mp4, .mov, .mkv, .webm, .avi, .wmv: "film"
        case .mp3, .m4a, .aac, .wav, .aiff, .flac, .ogg, .opus, .wma: "waveform"
        case .zip, .tar, .tgz: "doc.zipper"
        default: "doc"
        }
    }

    // MARK: Tools

    private static func toolsContent(_ items: [DroppedItem], _ caps: Capabilities,
                                     _ settings: CatalogSettings) -> WheelContent {
        guard let first = items.first else {
            return WheelContent(slices: [], hubMessage: "No tool fits every file")
        }
        let single = items.count == 1
        let categories = Set(items.map(\.category))

        let slices: [Slice]
        if categories.count > 1 {
            let allowed: Set<FileCategory> = [.image, .video, .audio, .pdf]
            guard categories.isSubset(of: allowed) else {
                return WheelContent(slices: [], hubMessage: "No tool fits every file")
            }
            slices = [
                tool(.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left",
                     children: tierChildren(parent: "tools.compress")),
                tool(.metadata, "REMOVE META", "eye.slash", preset: .metadataStripAll),
            ]
        } else {
            switch first.category {
            case .image: slices = imageTools(items, single, settings)
            case .video: slices = videoTools(items, single, settings)
            case .audio: slices = audioTools(items, single)
            case .pdf: slices = pdfTools(items, single, settings)
            case .archive: slices = [tool(.extract, "EXTRACT", "arrow.up.bin")]
            default:
                let ext = first.formatKey.uppercased()
                return WheelContent(slices: [], hubMessage: ext.isEmpty ? "No tool fits every file" : "No tools for \(ext) files")
            }
        }
        // Helper gating only applies when the selection would otherwise have tools (R12).
        if !slices.isEmpty, let message = missingHelperMessage(items, caps) {
            return WheelContent(slices: [], hubMessage: message)
        }
        return WheelContent(slices: capped(slices), hubMessage: nil)
    }

    /// Read helpers, plus ffmpeg for video/audio not natively writable (R5).
    private static func missingHelperMessage(_ items: [DroppedItem], _ caps: Capabilities) -> String? {
        for item in items {
            var needed = ConversionMatrix.readHelper(for: item)
            if needed == nil, item.category == .video || item.category == .audio,
               !MediaSupport.isNativelyWritable(formatKey: item.formatKey) {
                needed = .ffmpeg
            }
            if let helper = needed, !caps.has(helper) {
                return "Install \(helper.displayName) to edit \(item.formatKey.uppercased())"
            }
        }
        return nil
    }

    private static func imageTools(_ items: [DroppedItem], _ single: Bool, _ s: CatalogSettings) -> [Slice] {
        var out: [Slice] = [tool(.removeBackground, "REMOVE BG", "person.crop.rectangle")]
        if single {
            out.append(tool(.addBackground, "ADD BG", "rectangle.on.rectangle", editor: .addBackground))
            out.append(tool(.markup, "MARKUP", "pencil.tip.crop.circle", editor: .imageMarkup))
            out.append(tool(.adjust, "ADJUST", "slider.horizontal.3", editor: .imageAdjust))
        }
        var compress = tierChildren(parent: "tools.compress")
        compress += fitChildren(parent: "tools.compress", presets: s.imageFitPresets)
        if single {
            compress.append(Slice(id: "tools.compress.custom", title: "Custom…",
                                  action: .tool(.compress, nil), editor: .compressCustom))
        }
        out.append(tool(.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left", children: ring("tools.compress", compress)))
        var meta = [
            child("tools.metadata.stripAll", "Strip all", .tool(.metadata, .metadataStripAll)),
            child("tools.metadata.stripLocation", "Strip location", .tool(.metadata, .metadataStripLocation)),
        ]
        if single { meta.append(metadataEditChild()) }
        out.append(tool(.metadata, "METADATA", "info.circle", children: meta))
        out.append(tool(.readQR, "READ QR", "qrcode.viewfinder"))
        if !single { out.append(tool(.collage, "COLLAGE", "square.grid.2x2")) }
        return out
    }

    private static func videoTools(_ items: [DroppedItem], _ single: Bool, _ s: CatalogSettings) -> [Slice] {
        var compress = fitChildren(parent: "tools.compress", presets: s.videoFitPresets)
        compress += tierChildren(parent: "tools.compress")
        let speeds = [0.25, 0.5, 1.5, 2, 4].map { v in
            child("tools.speed.\(v)", "\(formatSpeed(v))×", .tool(.speed, .speed(v)))
        }
        var out: [Slice] = [tool(.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left", children: ring("tools.compress", compress))]
        if single {
            out.append(tool(.trim, "TRIM", "scissors", editor: .mediaTrim))
            out.append(tool(.crop, "CROP", "crop", editor: .videoCrop))
        }
        out.append(tool(.speed, "SPEED", "speedometer", children: speeds))
        if single {
            out.append(tool(.split, "SPLIT", "square.split.2x1", editor: .mediaSplit))
            out.append(tool(.snapshot, "SNAPSHOT", "camera", editor: .videoSnapshot))
        }
        out.append(tool(.mute, "MUTE", "speaker.slash"))
        out.append(tool(.removeMetadata, "REMOVE META", "eye.slash"))
        if !single { out.append(tool(.join, "JOIN", "rectangle.connected.to.line.below")) }
        return out
    }

    private static func audioTools(_ items: [DroppedItem], _ single: Bool) -> [Slice] {
        let lossless: Set<String> = ["wav", "aiff", "flac"]
        let note = items.contains { lossless.contains($0.formatKey) } ? "Saves as M4A" : nil
        var compress = [256, 192, 128, 96].map {
            child("tools.compress.bitrate.\($0)", "\($0) kbps", .tool(.compress, .bitrate($0)))
        }
        compress.append(child("tools.compress.bitrate.0", "Smaller", .tool(.compress, .bitrate(0))))
        let channels = [ChannelOp.toMono, .toStereo, .swap].map {
            child("tools.channels.\($0.rawValue)", $0.title, .tool(.channels, .channels($0)))
        }
        var meta = [child("tools.metadata.stripAll", "Strip all", .tool(.metadata, .metadataStripAll))]
        if single { meta.append(metadataEditChild()) }

        var out: [Slice] = [tool(.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left",
                                 subtitle: note, children: ring("tools.compress", compress))]
        if single { out.append(tool(.trim, "TRIM", "scissors", editor: .mediaTrim)) }
        out.append(tool(.normalize, "NORMALIZE", "waveform.path"))
        if single { out.append(tool(.bleep, "BLEEP", "speaker.wave.3", editor: .audioBleep)) }
        out.append(tool(.channels, "CHANNELS", "circle.lefthalf.filled", children: channels))
        out.append(tool(.metadata, "METADATA", "info.circle", children: meta))
        return out
    }

    private static func pdfTools(_ items: [DroppedItem], _ single: Bool, _ s: CatalogSettings) -> [Slice] {
        var compress = tierChildren(parent: "tools.compress")
        compress += fitChildren(parent: "tools.compress", presets: s.pdfFitPresets)
        var split = [child("tools.split.everyPage", "Every page", .tool(.split, .pdfSplitEveryPage))]
        if single {
            split.append(Slice(id: "tools.split.choose", title: "Choose pages…",
                               action: .tool(.split, nil), editor: .pdfSplit))
        }
        var out: [Slice] = [tool(.compress, "COMPRESS", "arrow.down.right.and.arrow.up.left", children: ring("tools.compress", compress))]
        if !single { out.append(tool(.merge, "MERGE", "doc.on.doc")) }
        out.append(tool(.split, "SPLIT", "square.split.2x1", children: split))
        if single {
            out.append(tool(.organize, "ORGANIZE", "square.grid.3x1.below.line.grid.1x2", editor: .pdfOrganize))
            out.append(tool(.redact, "REDACT", "rectangle.and.pencil.and.ellipsis", editor: .pdfRedact))
        }
        out.append(tool(.metadata, "METADATA", "info.circle", preset: .metadataStripAll))
        return out
    }

    // MARK: Actions

    private static func actionSlices(_ settings: CatalogSettings) -> [Slice] {
        var seen = Set<String>()
        let folders = settings.favouriteFolders.filter { seen.insert($0.path).inserted }
        func folderChildren(_ id: ActionID) -> [Slice] {
            // Reserve a slot for Choose… so it stays reachable; cap the whole ring.
            ring("actions.\(id.rawValue)", folders.map {
                child("actions.\(id.rawValue).\($0.path)", $0.lastPathComponent, .action(id, .folder($0)))
            } + [Slice(id: "actions.\(id.rawValue).choose", title: "Choose…",
                       action: .action(id, nil), editor: .chooseFolder)])
        }
        let paths = [PathStyle.posix, .uri].map {
            child("actions.copyPath.\($0.rawValue)", $0.title, .action(.copyPath, .pathStyle($0)))
        }
        let archive = [OutputFormat.zip, .tar, .tgz].map {
            child("actions.archive.\($0.rawValue)", $0.label, .action(.archive, .archive($0)))
        }
        return [
            act(.float, "FLOAT", "pin"),
            act(.airDrop, "AIRDROP", "dot.radiowaves.left.and.right"),
            act(.copyPath, "COPY PATH", "doc.on.clipboard", children: paths),
            act(.terminal, "TERMINAL", "terminal"),
            act(.copyTo, "COPY TO", "folder.badge.plus", children: folderChildren(.copyTo)),
            act(.moveTo, "MOVE TO", "folder", children: folderChildren(.moveTo)),
            act(.archive, "ARCHIVE", "doc.zipper", children: archive),
        ]
    }

    // MARK: Builders

    private static func tool(_ id: ToolID, _ title: String, _ symbol: String, subtitle: String? = nil,
                             preset: Preset? = nil, children: [Slice] = [], editor: EditorKind? = nil) -> Slice {
        let action: SliceAction? = children.isEmpty ? .tool(id, preset) : nil
        return Slice(id: "tools.\(id.rawValue)", title: title, subtitle: subtitle, symbol: symbol,
                     action: editor != nil ? .tool(id, nil) : action, children: children, editor: editor)
    }

    private static func act(_ id: ActionID, _ title: String, _ symbol: String, children: [Slice] = []) -> Slice {
        Slice(id: "actions.\(id.rawValue)", title: title, symbol: symbol,
              action: children.isEmpty ? .action(id, nil) : nil, children: children)
    }

    private static func child(_ id: String, _ title: String, _ action: SliceAction) -> Slice {
        Slice(id: id, title: title, action: action)
    }

    private static func metadataEditChild() -> Slice {
        Slice(id: "tools.metadata.edit", title: "View & edit…", action: .tool(.metadata, nil), editor: .metadataEdit)
    }

    private static func tierChildren(parent: String) -> [Slice] {
        CompressTier.allCases.map {
            child("\(parent).\($0.rawValue)", $0.title, .tool(.compress, .compress(.tier($0))))
        }
    }

    private static func fitChildren(parent: String, presets: [Int64]) -> [Slice] {
        unique(presets).map {
            child("\(parent).fit.\($0)", "Under \(byteTitle($0))", .tool(.compress, .compress(.fitUnder($0))))
        }
    }

    private static func formatSpeed(_ v: Double) -> String {
        v == v.rounded() ? String(Int(v)) : String(v)
    }

    static func byteTitle(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .replacingOccurrences(of: "\u{202F}", with: " ")
    }
}
