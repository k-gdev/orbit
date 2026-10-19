import CoreGraphics
import Foundation

/// Several images into one PDF, one page each, in the order given.
public enum ImagesToPDF {
    /// Each page is the image's pixel size × 72 / DPI points (DPI from its metadata, 72 if absent).
    public static func make(_ sources: [URL], output: URL) throws {
        try PDFWriter.write(count: sources.count, to: output) { index in
            let url = sources[index]
            return (try ImageFile.loadOriented(url), ImageFile.dpi(from: ImageFile.properties(url)))
        }
    }
}
