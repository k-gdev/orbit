import CoreGraphics
import CoreText
import Foundation
@testable import OrbitCore

/// PDF fixtures for the PDF processor tests.
extension Fixtures {
    /// A PDF with one page per string. The text is real (extractable) text near the top of the page.
    /// `embeddedImagePixels` adds a square photo-like image of that many pixels to the first page, drawn
    /// 200 points wide, as a lossless (Flate) image that JPEG recompression can shrink. `author` goes into
    /// both the Info dictionary and the XMP metadata, so a strip has to remove it from both.
    static func pdf(_ name: String, pages: [String], letter: Bool = true, embeddedImagePixels: Int? = nil,
                    author: String? = nil, in dir: URL) -> URL {
        let url = dir.appending(path: name, directoryHint: .notDirectory)
        var box = letter ? CGRect(x: 0, y: 0, width: 612, height: 792) : CGRect(x: 0, y: 0, width: 595, height: 842)
        var info: [String: Any] = [:]
        if let author { info[kCGPDFContextAuthor as String] = author }
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info.isEmpty ? nil : info as CFDictionary) else {
            preconditionFailure("Fixtures.pdf: no context")
        }
        if let author {
            let xmp = "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\">"
                + "<rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
                + "<rdf:Description xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:creator>\(author)</dc:creator>"
                + "</rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>"
            ctx.addDocumentMetadata(Data(xmp.utf8) as CFData)
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (index, text) in pages.enumerated() {
            ctx.beginPDFPage(nil)
            ctx.setFillColor(CGColor(gray: 0, alpha: 1))
            // A tab in the text starts a new column 150 points to the right.
            for (column, part) in text.components(separatedBy: "\t").enumerated() {
                let attributed = NSAttributedString(string: part, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ])
                ctx.textPosition = CGPoint(x: 72 + 150 * CGFloat(column), y: box.height - 90)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), ctx)
            }
            if index == 0, let pixels = embeddedImagePixels {
                ctx.draw(photoLike(pixels), in: CGRect(x: 72, y: box.height - 330, width: 200, height: 200))
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        return url
    }

    /// A square gradient with fine pseudo-random texture: large when stored losslessly, small as JPEG.
    private static func photoLike(_ pixels: Int) -> CGImage {
        guard let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: pixels * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let data = ctx.data else { preconditionFailure("Fixtures.photoLike: no context") }
        let buffer = data.bindMemory(to: UInt8.self, capacity: pixels * pixels * 4)
        var state: UInt32 = 0x9E3779B9
        for y in 0..<pixels {
            for x in 0..<pixels {
                state ^= state << 13; state ^= state >> 17; state ^= state << 5
                let noise = Int(state & 0x0F)
                let base = (y * pixels + x) * 4
                buffer[base] = UInt8(min(255, x * 200 / pixels + noise))
                buffer[base + 1] = UInt8(min(255, y * 200 / pixels + noise))
                buffer[base + 2] = UInt8(min(255, (x + y) * 100 / pixels + noise))
                buffer[base + 3] = 255
            }
        }
        guard let image = ctx.makeImage() else { preconditionFailure("Fixtures.photoLike: no image") }
        return image
    }
}
