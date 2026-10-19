import AppKit
import QuickLookThumbnailing

enum Thumbnails {
    /// A Quick Look thumbnail (or, failing that, the file's icon) at `size` points,
    /// rendered for a 2× display. Nil when Quick Look can't produce either.
    static func image(for url: URL, size: CGSize) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: 2,
                                                   representationTypes: [.thumbnail, .icon])
        do {
            return try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        } catch {
            return nil
        }
    }
}
