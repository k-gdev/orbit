import CoreGraphics
import Foundation

/// Several images into one PDF, one page each, in the order given.
public enum ImagesToPDF {
    /// Each page is the image's pixel size × 72 / DPI points (DPI from its metadata, 72 if absent).
    public static func make(_ sources: [URL], output: URL) throws {
        var pages: [(image: CGImage, dpi: Double)] = []
        for url in sources {
            try Task.checkCancellation()
            let dpi = ImageFile.dpi(from: ImageFile.properties(url))
            pages.append((try ImageFile.loadOriented(url), dpi))
        }
        try PDFWriter.write(pages, to: output)
    }
}
