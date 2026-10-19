import Foundation

/// Byte-level work on a baseline or progressive JPEG's marker segments, without touching the
/// entropy-coded scan data (so the pixels stay bit-identical).
enum JPEGSegments {
    private struct Segment {
        let marker: UInt8
        /// The whole segment: `FF`, the marker, the length and the payload.
        let range: Range<Int>
        let payload: Range<Int>
    }

    /// The segments before the first SOS, and the offset where SOS starts. Nil when `bytes` is not
    /// a well-formed JPEG header.
    private static func header(_ b: [UInt8]) -> (segments: [Segment], scanStart: Int)? {
        guard b.count > 4, b[0] == 0xFF, b[1] == 0xD8 else { return nil }
        var i = 2
        var segments: [Segment] = []
        while i + 4 <= b.count {
            guard b[i] == 0xFF else { return nil }
            var m = i + 1
            while m < b.count, b[m] == 0xFF { m += 1 } // fill bytes
            guard m + 2 < b.count else { return nil }
            let marker = b[m]
            if marker == 0xDA { return (segments, i) }
            if marker == 0xD9 || marker == 0x01 || (0xD0...0xD7).contains(marker) { return nil }
            let length = Int(b[m + 1]) << 8 | Int(b[m + 2])
            guard length >= 2, m + 1 + length <= b.count else { return nil }
            segments.append(Segment(marker: marker, range: i..<(m + 1 + length), payload: (m + 3)..<(m + 1 + length)))
            i = m + 1 + length
        }
        return nil
    }

    private static func payloadStarts(_ b: [UInt8], _ s: Segment, with prefix: String) -> Bool {
        let p = Array(prefix.utf8)
        return s.payload.count >= p.count && Array(b[s.payload.lowerBound..<(s.payload.lowerBound + p.count)]) == p
    }

    /// True when an APP1 (EXIF) segment holds an embedded thumbnail, i.e. a second JPEG.
    static func hasEmbeddedThumbnail(_ data: Data) -> Bool {
        let b = [UInt8](data)
        guard let (segments, _) = header(b) else { return false }
        for s in segments where s.marker == 0xE1 {
            let p = s.payload
            guard p.count > 3 else { continue }
            for k in p.lowerBound..<(p.upperBound - 2) where b[k] == 0xFF && b[k + 1] == 0xD8 && b[k + 2] == 0xFF {
                return true
            }
        }
        return false
    }

    /// The same image with only the segments a decoder needs: JFIF (APP0), the ICC profile (APP2
    /// `ICC_PROFILE`), Adobe (APP14, for the colour transform) and every non-APP segment. EXIF and
    /// XMP (APP1), MPF and other APP2 data, IPTC/Photoshop (APP13), other APPn, comments and
    /// anything after the end-of-image marker (e.g. an appended gain map) are dropped.
    static func strippingMetadata(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard let (segments, scanStart) = header(b), let end = endOfImage(b, from: scanStart) else { return nil }
        var out: [UInt8] = [0xFF, 0xD8]
        out.reserveCapacity(b.count)
        for s in segments {
            let keep: Bool
            switch s.marker {
            case 0xE0: keep = payloadStarts(b, s, with: "JFIF")
            case 0xE2: keep = payloadStarts(b, s, with: "ICC_PROFILE\0")
            case 0xEE: keep = payloadStarts(b, s, with: "Adobe")
            case 0xE1, 0xE3...0xED, 0xEF, 0xFE: keep = false
            default: keep = true
            }
            if keep { out += b[s.range] }
        }
        out += b[scanStart..<end]
        return Data(out)
    }

    /// Inserts a minimal EXIF APP1 that holds only the Orientation tag (after SOI, or after a
    /// leading JFIF APP0). Assumes the image has no EXIF segment of its own.
    static func insertingOrientation(_ orientation: Int, into data: Data) -> Data? {
        let b = [UInt8](data)
        guard (1...8).contains(orientation), let (segments, _) = header(b),
              !segments.contains(where: { $0.marker == 0xE1 && payloadStarts(b, $0, with: "Exif\0\0") }) else { return nil }
        // "Exif\0\0", big-endian TIFF header, IFD0 with one SHORT entry (0x0112), no next IFD.
        let tiff: [UInt8] = [0x4D, 0x4D, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x08,
                             0x00, 0x01,
                             0x01, 0x12, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, UInt8(orientation), 0x00, 0x00,
                             0x00, 0x00, 0x00, 0x00]
        let payload = Array("Exif\0\0".utf8) + tiff
        let length = payload.count + 2
        let app1: [UInt8] = [0xFF, 0xE1, UInt8(length >> 8), UInt8(length & 0xFF)] + payload
        var at = 2
        if let first = segments.first, first.marker == 0xE0, first.range.lowerBound == 2 { at = first.range.upperBound }
        return Data(b[0..<at] + app1 + b[at...])
    }

    /// The offset just past the first end-of-image marker at or after `from` (the first SOS).
    /// In scan data `FF` is followed by `00` (stuffing), a restart marker or a real marker, so the
    /// first `FF D9` is the image's end.
    private static func endOfImage(_ b: [UInt8], from: Int) -> Int? {
        var i = from
        while i + 1 < b.count {
            if b[i] == 0xFF && b[i + 1] == 0xD9 { return i + 2 }
            i += 1
        }
        return nil
    }
}
