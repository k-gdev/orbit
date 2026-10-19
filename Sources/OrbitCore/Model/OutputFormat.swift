import Foundation

public enum OutputFormat: String, CaseIterable, Codable, Sendable {
    case jpg, png, heic, webp, tiff, avif, bmp, gif, ico, pdf
    case mp4, mov, mkv, webm, avi, wmv
    case mp3, m4a, aac, wav, aiff, flac, ogg, opus, wma
    case docx, pages, txt, md, html, epub, pptx, key, xlsx, csv, tsv, numbers, ods, srt, vtt
    case zip, tar, tgz

    public var fileExtension: String {
        self == .tgz ? "tar.gz" : rawValue
    }

    public var label: String {
        self == .tgz ? "TAR.GZ" : rawValue.uppercased()
    }
}
