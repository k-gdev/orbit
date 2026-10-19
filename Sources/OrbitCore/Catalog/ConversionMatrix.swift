import Foundation

public enum ConversionMatrix {
    private static let archives: [OutputFormat] = [.zip, .tar, .tgz]

    /// Convert outputs for one item, in slice order. The item's own format is omitted.
    public static func outputs(for item: DroppedItem) -> [OutputFormat] {
        table(for: item.category).filter { $0.fileExtension != item.formatKey && $0.rawValue != item.formatKey }
    }

    /// The category's full convert table, in slice order, including the source's own format.
    public static func table(for category: FileCategory) -> [OutputFormat] {
        let all: [OutputFormat]
        switch category {
        case .image: all = [.jpg, .png, .heic, .webp, .tiff, .avif, .bmp, .gif, .ico, .pdf]
        case .video: all = [.mp4, .mov, .mkv, .webm, .avi, .wmv, .gif, .m4a, .mp3]
        case .audio: all = [.m4a, .aac, .wav, .aiff, .flac, .mp3, .ogg, .opus, .wma]
        case .pdf: all = [.jpg, .png, .txt, .md, .docx, .epub, .pages, .pptx, .xlsx]
        case .document: all = [.pdf, .docx, .txt, .md, .html, .epub, .pages]
        case .slides: all = [.pdf, .jpg, .png, .pptx, .key]
        case .spreadsheet: all = [.xlsx, .csv, .tsv, .pdf, .numbers, .ods]
        case .subtitle: all = [.srt, .vtt, .txt]
        case .archive, .folder: all = archives
        case .other: all = []
        }
        return all
    }

    /// Helper needed to read this item, if any.
    public static func readHelper(for item: DroppedItem) -> Helper? {
        if MediaSupport.needsFFmpegToRead(item) { return .ffmpeg }
        switch item.formatKey {
        case "pages": return .pages
        case "pptx", "ppt", "key": return .keynote
        case "xlsx", "xls", "numbers": return .numbers
        default: return nil
        }
    }

    /// Helper needed to write `output` from this item, if any.
    public static func outputHelper(for item: DroppedItem, output: OutputFormat) -> Helper? {
        switch output {
        case .pages: return .pages
        case .numbers: return .numbers
        case .pdf where item.category == .spreadsheet: return .numbers
        case .mkv, .webm, .avi, .wmv, .mp3, .ogg, .opus, .wma:
            return (item.category == .video || item.category == .audio) ? .ffmpeg : nil
        default: return nil
        }
    }

    public static func subtitle(for item: DroppedItem, output: OutputFormat, itemCount: Int) -> String? {
        switch (item.category, output) {
        case (.image, .pdf): return itemCount > 1 ? "One PDF" : nil
        case (.pdf, .docx), (.pdf, .epub): return "Text only"
        case (.pdf, .pptx): return "Pages as slides"
        case (.pdf, .xlsx): return "Best effort"
        default: return nil
        }
    }
}
