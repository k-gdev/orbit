import CoreGraphics
import Foundation

/// Several images into one PDF, one page each, in the order given.
public enum ImagesToPDF {
    /// Each page is the image's upright pixel size × 72 / DPI points (DPI from its metadata, 72 if
    /// absent). JPEG pages keep their compressed data (R36, see `ImageFile.pdfPage`).
    public static func make(_ sources: [URL], output: URL) throws {
        try PDFWriter.write(count: sources.count, to: output) { index in try ImageFile.pdfPage(sources[index]) }
    }
}
