import Foundation

public enum WheelKind: String, Codable, CaseIterable, Sendable { case convert, tools, actions }

public enum ToolID: String, Codable, Sendable {
    case removeBackground, addBackground, markup, adjust, compress, metadata, readQR, collage
    case trim, crop, speed, split, snapshot, mute, removeMetadata, join
    case normalize, bleep, channels
    case merge, organize, redact
    case extract
}

public enum ActionID: String, Codable, Sendable {
    case float, airDrop, copyPath, terminal, copyTo, moveTo, archive, shelf
}

public enum EditorKind: String, Sendable {
    case imageMarkup, imageAdjust, addBackground, mediaTrim, videoCrop, mediaSplit, videoSnapshot
    case audioBleep, pdfRedact, pdfOrganize, pdfSplit, metadataEdit, compressCustom, chooseFolder
}

public enum CompressTier: String, CaseIterable, Sendable {
    case light, medium, strong

    public var targetFraction: Double {
        switch self {
        case .light: 0.75
        case .medium: 0.5
        case .strong: 0.25
        }
    }

    public var title: String {
        switch self {
        case .light: "Light"
        case .medium: "Medium"
        case .strong: "Strong"
        }
    }
}

public enum CompressTarget: Hashable, Sendable {
    case tier(CompressTier)
    case fitUnder(Int64)
}

public enum ChannelOp: String, Sendable {
    case toMono, toStereo, swap

    public var title: String {
        switch self {
        case .toMono: "Mono"
        case .toStereo: "Stereo"
        case .swap: "Swap L/R"
        }
    }
}

public enum PathStyle: String, Sendable {
    case posix, uri

    public var title: String {
        switch self {
        case .posix: "POSIX"
        case .uri: "URI"
        }
    }
}

public enum Preset: Hashable, Sendable {
    case compress(CompressTarget)
    case speed(Double)
    case bitrate(Int) // 0 = Smaller
    case channels(ChannelOp)
    case metadataStripAll
    case metadataStripLocation
    case pdfSplitEveryPage
    case pathStyle(PathStyle)
    case folder(URL)
    case archive(OutputFormat)
}

public enum SliceAction: Hashable, Sendable {
    case convert(OutputFormat)
    case tool(ToolID, Preset?)
    case action(ActionID, Preset?)
}

public struct Slice: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let symbol: String?
    public let action: SliceAction?
    public let children: [Slice]
    public let editor: EditorKind?

    public init(id: String, title: String, subtitle: String? = nil, symbol: String? = nil,
                action: SliceAction? = nil, children: [Slice] = [], editor: EditorKind? = nil) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.action = action
        self.children = children
        self.editor = editor
    }
}

public struct WheelContent: Equatable, Sendable {
    public let slices: [Slice]
    public let hubMessage: String?

    public init(slices: [Slice], hubMessage: String? = nil) {
        self.slices = slices
        self.hubMessage = hubMessage
    }
}
