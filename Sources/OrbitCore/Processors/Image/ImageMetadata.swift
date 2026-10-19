import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Reading, stripping and editing the metadata of an image file without touching its pixels.
public enum ImageMetadata {
    public static let editableKeys: [MetadataKey] = [.dateTaken, .artist, .copyright, .description]

    public static func read(_ url: URL) -> [MetadataField] {
        let props = ImageFile.properties(url)
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]

        func text(_ dict: [CFString: Any], _ key: CFString) -> String? {
            guard let value = dict[key] else { return nil }
            let s = "\(value)".trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }
        func coordinate(_ value: Any?, ref: Any?, negative: String) -> String? {
            guard let number = (value as? NSNumber)?.doubleValue else { return nil }
            let signed = (ref as? String)?.uppercased() == negative ? -abs(number) : abs(number)
            return String(signed)
        }

        let w = props[kCGImagePropertyPixelWidth] as? Int, h = props[kCGImagePropertyPixelHeight] as? Int
        let values: [(MetadataKey, String, String?)] = [
            (.cameraMake, "Camera make", text(tiff, kCGImagePropertyTIFFMake)),
            (.cameraModel, "Camera model", text(tiff, kCGImagePropertyTIFFModel)),
            (.lens, "Lens", text(exif, kCGImagePropertyExifLensModel)),
            (.dateTaken, "Date taken", text(exif, kCGImagePropertyExifDateTimeOriginal)),
            (.gpsLatitude, "Latitude", coordinate(gps[kCGImagePropertyGPSLatitude], ref: gps[kCGImagePropertyGPSLatitudeRef], negative: "S")),
            (.gpsLongitude, "Longitude", coordinate(gps[kCGImagePropertyGPSLongitude], ref: gps[kCGImagePropertyGPSLongitudeRef], negative: "W")),
            (.serialNumber, "Serial number", text(exif, kCGImagePropertyExifBodySerialNumber) ?? text(aux, kCGImagePropertyExifAuxSerialNumber)),
            (.software, "Software", text(tiff, kCGImagePropertyTIFFSoftware)),
            (.artist, "Artist", text(tiff, kCGImagePropertyTIFFArtist)),
            (.copyright, "Copyright", text(tiff, kCGImagePropertyTIFFCopyright)),
            (.description, "Description", text(tiff, kCGImagePropertyTIFFImageDescription)),
            (.title, "Title", text(iptc, kCGImagePropertyIPTCObjectName)),
            (.pixelSize, "Size", (w != nil && h != nil) ? "\(w!) × \(h!)" : nil),
        ]
        // Editable fields are always listed (empty when unset) so an editor can fill them in.
        return values.compactMap { key, label, value in
            let editable = editableKeys.contains(key)
            guard value != nil || editable else { return nil }
            return MetadataField(key: key, label: label, value: value ?? "", editable: editable)
        }
    }

    /// Copies the image to `to` without the metadata: everything for `locationOnly == false`
    /// (orientation is kept so the picture still shows upright), just GPS otherwise.
    /// Encoded pixels are copied, not re-encoded, whenever ImageIO can do that for the format.
    public static func strip(_ src: URL, to: URL, locationOnly: Bool) throws {
        let source = try imageSource(src)
        let props = ImageFile.properties(src)

        // Lossless path: the metadata tree is replaced (strip all) or merged (GPS only).
        // kCGImageDestinationOrientation can't be combined with kCGImageDestinationMetadata (the copy
        // then always fails), so orientation goes into the tree, or for JPEG into a minimal EXIF
        // segment written afterwards: a tree orientation would keep JPEG's EXIF thumbnail.
        let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let isJPEG = (CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier
        var options: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if locationOnly {
            options[kCGImageDestinationMergeMetadata] = true
        } else {
            let tree = CGImageMetadataCreateMutable()
            if orientation != 1 && !isJPEG {
                CGImageMetadataSetValueWithPath(tree, nil, "tiff:Orientation" as CFString, "\(orientation)" as CFString)
            }
            options[kCGImageMetadataShouldExcludeXMP] = true
            options[kCGImageDestinationMetadata] = tree
            options[kCGImageDestinationMergeMetadata] = false
        }
        if try copyLosslessly(source, to: to, options: options),
           locationOnly || !isJPEG || orientation == 1 || insertOrientation(orientation, into: to),
           verifyStripped(to, locationOnly: locationOnly, orientation: locationOnly ? nil : orientation) { return }
        try? FileManager.default.removeItem(at: to)

        // Fallback: property dictionaries nulled while the image is re-added from the source.
        var replacement: [CFString: Any] = [kCGImagePropertyGPSDictionary: kCFNull as Any]
        var fallback: [CFString: Any] = [kCGImageMetadataShouldExcludeGPS: true]
        if !locationOnly {
            for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                        kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyGIFDictionary,
                        kCGImagePropertyMakerAppleDictionary, kCGImagePropertyMakerCanonDictionary,
                        kCGImagePropertyMakerNikonDictionary, kCGImagePropertyMakerFujiDictionary,
                        kCGImagePropertyMakerOlympusDictionary, kCGImagePropertyMakerPentaxDictionary,
                        kCGImagePropertyMakerMinoltaDictionary] {
                replacement[key] = kCFNull as Any
            }
            if let orientation = props[kCGImagePropertyOrientation] { replacement[kCGImagePropertyOrientation] = orientation }
            fallback[kCGImageMetadataShouldExcludeXMP] = true
        }
        try reencode(source, to: to, properties: replacement, options: fallback)
    }

    /// Writes a copy with `edits` applied (keys are `MetadataKey` raw values: dateTaken, artist,
    /// copyright, description). An empty value removes the field.
    public static func write(_ src: URL, to: URL, edits: [String: String]) throws {
        let source = try imageSource(src)
        var tiff: [CFString: Any] = [:]
        var exif: [CFString: Any] = [:]
        var iptc: [CFString: Any] = [:] // ImageIO mirrors these TIFF tags into IPTC and reads them back from there
        let tree = CGImageMetadataCreateMutable()
        func tag(_ path: String, _ value: String) {
            CGImageMetadataSetValueWithPath(tree, nil, path as CFString, value.isEmpty ? kCFNull : value as CFString)
        }
        for (rawKey, value) in edits {
            guard let key = MetadataKey(rawValue: rawKey), editableKeys.contains(key) else { continue }
            let stored: Any = value.isEmpty ? kCFNull as Any : value
            switch key {
            case .dateTaken:
                exif[kCGImagePropertyExifDateTimeOriginal] = stored
                exif[kCGImagePropertyExifDateTimeDigitized] = stored
                tag("exif:DateTimeOriginal", value)
                tag("exif:DateTimeDigitized", value)
                if value.isEmpty {
                    iptc[kCGImagePropertyIPTCDateCreated] = stored
                    iptc[kCGImagePropertyIPTCTimeCreated] = stored
                }
            case .artist:
                tiff[kCGImagePropertyTIFFArtist] = stored
                tag("tiff:Artist", value)
                CGImageMetadataSetValueWithPath(tree, nil, "dc:creator" as CFString, value.isEmpty ? kCFNull : [value] as CFArray)
                iptc[kCGImagePropertyIPTCByline] = value.isEmpty ? stored : [value]
            case .copyright:
                tiff[kCGImagePropertyTIFFCopyright] = stored
                tag("tiff:Copyright", value)
                iptc[kCGImagePropertyIPTCCopyrightNotice] = stored
            case .description:
                tiff[kCGImagePropertyTIFFImageDescription] = stored
                tag("tiff:ImageDescription", value)
                iptc[kCGImagePropertyIPTCCaptionAbstract] = stored
            default: break
            }
        }
        // Lossless path first; kept only if the edits read back exactly.
        let lossless: [CFString: Any] = [kCGImageDestinationMetadata: tree, kCGImageDestinationMergeMetadata: true]
        if try copyLosslessly(source, to: to, options: lossless), appliedEdits(edits, at: to) { return }
        try? FileManager.default.removeItem(at: to)

        var replacement: [CFString: Any] = [:]
        if !tiff.isEmpty { replacement[kCGImagePropertyTIFFDictionary] = tiff }
        if !exif.isEmpty { replacement[kCGImagePropertyExifDictionary] = exif }
        if !iptc.isEmpty { replacement[kCGImagePropertyIPTCDictionary] = iptc }
        try reencode(source, to: to, properties: replacement, options: [:])
    }

    public static func mapLink(lat: Double, lon: Double) -> URL {
        URL(string: "https://maps.apple.com/?ll=\(lat),\(lon)") ?? URL(fileURLWithPath: "/")
    }

    private static func imageSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else {
            throw OrbitError.unsupported("Orbit can't read this image.")
        }
        return source
    }

    /// `CGImageDestinationCopyImageSource`: the encoded image data is carried over untouched. False
    /// when ImageIO can't do that for this format; any partial file is removed.
    private static func copyLosslessly(_ source: CGImageSource, to url: URL, options: [CFString: Any]) throws -> Bool {
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw OrbitError.unsupported("Orbit can't edit the metadata of this kind of image.")
        }
        var error: Unmanaged<CFError>?
        let ok = CGImageDestinationCopyImageSource(destination, source, options as CFDictionary, &error)
        error?.release()
        if !ok { try? FileManager.default.removeItem(at: url) }
        return ok
    }

    private static func appliedEdits(_ edits: [String: String], at url: URL) -> Bool {
        let fields = read(url)
        for (rawKey, value) in edits {
            guard let key = MetadataKey(rawValue: rawKey), editableKeys.contains(key) else { continue }
            if fields.first(where: { $0.key == key })?.value != value { return false }
        }
        return true
    }

    /// Rewrites the JPEG Orbit just wrote at `url` with an EXIF segment holding only `orientation`.
    private static func insertOrientation(_ orientation: Int, into url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let tagged = JPEGSegments.insertingOrientation(orientation, into: data) else { return false }
        return (try? tagged.write(to: url, options: .atomic)) != nil
    }

    /// Whether the written file is free of the metadata a strip promises to remove, and (when
    /// `orientation` is given) still shows the picture the same way up.
    private static func verifyStripped(_ url: URL, locationOnly: Bool, orientation: Int? = nil) -> Bool {
        let props = ImageFile.properties(url)
        if props[kCGImagePropertyGPSDictionary] != nil { return false }
        if locationOnly { return true }
        if let orientation, ((props[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1) != orientation { return false }
        if let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.starts(with: [0xFF, 0xD8]),
           JPEGSegments.hasEmbeddedThumbnail(data) { return false }
        let gone: [CFString] = [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary, kCGImagePropertyTIFFDictionary,
                                kCGImagePropertyIPTCDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyMakerAppleDictionary]
        for key in gone {
            guard let dict = props[key] as? [CFString: Any] else { continue }
            // Dimensions, colour space and orientation are structural, not personal.
            let personal = dict.keys.filter { ![kCGImagePropertyExifPixelXDimension, kCGImagePropertyExifPixelYDimension,
                                                kCGImagePropertyExifColorSpace, kCGImagePropertyTIFFOrientation,
                                                kCGImagePropertyPNGInterlaceType, kCGImagePropertyPNGXPixelsPerMeter,
                                                kCGImagePropertyPNGYPixelsPerMeter, kCGImagePropertyPNGGamma,
                                                kCGImagePropertyPNGsRGBIntent].contains($0) }
            if !personal.isEmpty { return false }
        }
        return true
    }

    private static func reencode(_ source: CGImageSource, to url: URL, properties: [CFString: Any],
                                 options: [CFString: Any]) throws {
        guard let type = CGImageSourceGetType(source),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else {
            throw OrbitError.unsupported("Orbit can't edit the metadata of this kind of image.")
        }
        var merged = options
        for (key, value) in properties { merged[key] = value }
        CGImageDestinationAddImageFromSource(destination, source, 0, merged as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            try? FileManager.default.removeItem(at: url)
            throw OrbitError.unsupported("Orbit couldn't write this image.")
        }
    }
}
