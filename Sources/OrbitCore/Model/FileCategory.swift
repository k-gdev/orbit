import Foundation

public enum FileCategory: String, Codable, Sendable {
    case image, video, audio, pdf, document, slides, spreadsheet, subtitle, archive, folder, other
}
