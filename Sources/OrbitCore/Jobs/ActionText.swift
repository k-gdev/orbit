import Foundation

extension SliceAction {
    /// The progress panel's title, for example "Converting to MP4".
    public func progressTitle(for category: FileCategory) -> String {
        switch self {
        case .convert(let format):
            return "Converting to \(format.label)"
        case .tool(let tool, _):
            switch tool {
            case .removeBackground: return "Removing background"
            case .addBackground: return "Adding background"
            case .markup: return "Saving markup"
            case .adjust: return "Adjusting photo"
            case .compress: return "Compressing"
            case .metadata: return stripsMetadata ? "Removing metadata" : "Saving metadata"
            case .readQR: return "Reading QR code"
            case .collage: return "Making collage"
            case .trim: return category == .audio ? "Trimming audio" : "Trimming video"
            case .crop: return "Cropping video"
            case .speed: return "Changing speed"
            case .split:
                switch category {
                case .pdf: return "Splitting PDF"
                case .audio: return "Splitting audio"
                default: return "Splitting video"
                }
            case .snapshot: return "Saving snapshot"
            case .mute: return "Muting video"
            case .removeMetadata: return "Removing metadata"
            case .join: return "Joining videos"
            case .normalize: return "Normalizing audio"
            case .bleep: return "Bleeping audio"
            case .channels: return "Changing channels"
            case .merge: return "Merging PDFs"
            case .organize: return "Organizing pages"
            case .redact: return "Redacting"
            case .extract: return "Extracting"
            }
        case .action(let action, _):
            switch action {
            case .copyTo: return "Copying"
            case .moveTo: return "Moving"
            case .archive: return "Archiving"
            case .copyPath: return "Copying path"
            // The app handles these before JobRunner; titles exist only for completeness.
            case .float: return "Floating"
            case .airDrop: return "Sharing with AirDrop"
            case .terminal: return "Opening Terminal"
            }
        }
    }

    /// The `<suffix>` in `<stem>-<suffix>.<ext>`; empty when the action names outputs itself.
    public var outputSuffix: String {
        switch self {
        case .convert:
            return "converted"
        case .tool(let tool, let preset):
            switch tool {
            case .removeBackground: return "nobg"
            case .addBackground: return "bg"
            case .markup: return "edited"
            case .adjust: return "adjusted"
            case .compress: return "compressed"
            case .metadata: return stripsMetadata ? "clean" : "edited"
            case .collage: return "collage"
            case .trim: return "trimmed"
            case .crop: return "cropped"
            case .speed:
                guard case .speed(let factor)? = preset else { return "" }
                return "\(Self.speedText(factor))x"
            case .split: return "part"
            case .snapshot: return "snapshot"
            case .mute: return "muted"
            case .removeMetadata: return "clean"
            case .join: return "joined"
            case .normalize: return "normalized"
            case .bleep: return "bleeped"
            case .channels:
                guard case .channels(let op)? = preset else { return "" }
                switch op {
                case .toMono: return "mono"
                case .toStereo: return "stereo"
                case .swap: return "swapped"
                }
            case .merge: return "merged"
            case .organize: return "organized"
            case .redact: return "redacted"
            case .readQR, .extract: return ""
            }
        case .action:
            return ""
        }
    }

    /// Whether every item goes to the processor as one unit (one output for the whole selection).
    public func isCombining(for items: [DroppedItem]) -> Bool {
        switch self {
        case .convert(.pdf):
            return items.count > 1 && items.allSatisfy { $0.category == .image }
        case .convert(.zip), .convert(.tar), .convert(.tgz):
            return !items.allSatisfy { $0.category == .archive }
        case .convert:
            return false
        case .tool(let tool, _):
            return tool == .collage || tool == .merge || tool == .join
        case .action(let action, _):
            return action == .archive
        }
    }

    private var stripsMetadata: Bool {
        switch self {
        case .tool(_, .metadataStripAll?), .tool(_, .metadataStripLocation?): true
        default: false
        }
    }

    /// `2` → "2", `0.5` → "0.5" (no trailing ".0").
    private static func speedText(_ factor: Double) -> String {
        if factor.isFinite, factor == factor.rounded(), abs(factor) < 1e15 { return String(Int(factor)) }
        return String(factor)
    }
}
