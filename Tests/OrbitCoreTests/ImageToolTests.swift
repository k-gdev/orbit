import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import OrbitCore

@Suite final class ImageToolTests {
    let root = Fixtures.tempDir()
    let fallback: URL
    static let parrot = "/Library/User Pictures/Animals/Parrot.heic"

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func runner() -> JobRunner {
        let rootPath = root.path + "/"
        return JobRunner(
            processors: ProcessorRegistry.standard(capabilities: Fixtures.caps), capabilities: Fixtures.caps,
            fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
    }

    private func run(_ urls: [URL], _ action: SliceAction, parameters: ToolParameters = .none) async throws -> JobResult {
        try await runner().run(JobRequest(items: urls.map(DroppedItem.init(url:)), action: action, parameters: parameters),
                               progress: { _ in })
    }

    private func fileSize(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    private func item(_ name: String) -> DroppedItem { DroppedItem(url: root.appending(path: name)) }

    // MARK: Remove background

    @Test(.enabled(if: FileManager.default.fileExists(atPath: ImageToolTests.parrot)))
    func removesBackground() async throws {
        let copy = root.appending(path: "Parrot.heic")
        // The system file is a symlink; copy its bytes.
        try Data(contentsOf: URL(fileURLWithPath: Self.parrot)).write(to: copy, options: .withoutOverwriting)
        let r = try await run([copy], .tool(.removeBackground, nil))
        let out = try #require(r.outputs.first)
        #expect(out.pathExtension == "png")
        #expect(out.lastPathComponent == "Parrot-nobg.png")
        let a = Fixtures.alphaHistogram(out)
        #expect(a.transparent > 0.10 && a.opaque > 0.10)
    }

    @Test func noSubjectErrors() async throws {
        let blank = Fixtures.image("blank.png", w: 200, h: 200, in: root)
        #expect(throws: OrbitError.noSubject) { try BackgroundRemover.cutout(blank) }
        await #expect(throws: OrbitError.noSubject) { try await self.run([blank], .tool(.removeBackground, nil)) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("nobg") }.isEmpty)
    }

    // MARK: Compress

    @Test func compressMediumHalves() async throws {
        let src = Fixtures.noisyJPEG(2000, 1500, q: 0.98, in: root)
        let r = try await run([src], .tool(.compress, .compress(.tier(.medium))))
        let out = try #require(r.outputs.first)
        #expect(try fileSize(out) <= fileSize(src) / 2)
        #expect(out.lastPathComponent.hasSuffix("-compressed.jpg"))
    }

    @Test func fitUnder() async throws {
        let src = Fixtures.noisyJPEG(2000, 1500, q: 0.98, in: root)
        let r = try await run([src], .tool(.compress, .compress(.fitUnder(150_000))))
        #expect(try fileSize(#require(r.outputs.first)) <= 150_000)
    }

    @Test func compressFromParameters() async throws {
        let src = Fixtures.noisyJPEG(800, 600, q: 0.95, in: root)
        let r = try await run([src], .tool(.compress, nil), parameters: .compress(.fitUnder(60_000)))
        #expect(try fileSize(#require(r.outputs.first)) <= 60_000)
    }

    /// Ruling R35: never re-encode into a file that may be bigger than one already under the target.
    @Test func fitUnderAlreadyUnderWritesNothing() async throws {
        let src = Fixtures.noisyJPEG(64, 48, in: root)
        let r = try await run([src], .tool(.compress, .compress(.fitUnder(10_000_000))))
        #expect(r.summary == "Already under 10 MB.")
        #expect(r.outputs.isEmpty && r.undo == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("compressed") }.isEmpty)
        let custom = try await run([src], .tool(.compress, nil), parameters: .compress(.fitUnder(5_000_000)))
        #expect(custom.summary == "Already under 5 MB." && custom.outputs.isEmpty)
    }

    @Test func fitUnderImpossible() async throws {
        let src = Fixtures.noisyJPEG(400, 300, in: root)
        await #expect(throws: OrbitError.targetTooSmall("Can't get this image under 100 bytes.")) {
            try await self.run([src], .tool(.compress, .compress(.fitUnder(100))))
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains("compressed") }.isEmpty)
        #expect(throws: OrbitError.targetTooSmall("Can't get this image under 100 bytes.")) {
            try ImageCompressor.compress(src, target: .fitUnder(100), format: .jpg,
                                         to: root.appending(path: "x.jpg"), options: JobOptions())
        }
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "x.jpg").path))
    }

    @Test func compressPNGDownscales() async throws {
        let src = Fixtures.image("noise.png", w: 600, h: 400, alpha: true, noise: true, in: root)
        let r = try await run([src], .tool(.compress, .compress(.tier(.medium))))
        let out = try #require(r.outputs.first)
        #expect(out.pathExtension == "png")
        #expect(try fileSize(out) <= fileSize(src) / 2)
        #expect(Fixtures.size(out).width < 600)
    }

    @Test func compressFormats() {
        let all: (OutputFormat) -> Bool = { _ in true }
        #expect(ImageCompressor.outputFormat(for: item("a.png"), hasAlpha: true, canWrite: all) == .png)
        #expect(ImageCompressor.outputFormat(for: item("a.png"), hasAlpha: false, canWrite: all) == .jpg)
        #expect(ImageCompressor.outputFormat(for: item("a.heic"), hasAlpha: false, canWrite: all) == .heic)
        #expect(ImageCompressor.outputFormat(for: item("a.jpeg"), hasAlpha: true, canWrite: all) == .jpg)
        #expect(ImageCompressor.outputFormat(for: item("a.webp"), hasAlpha: true, canWrite: all) == .webp)
        #expect(ImageCompressor.outputFormat(for: item("a.avif"), hasAlpha: false, canWrite: all) == .avif)
        #expect(ImageCompressor.outputFormat(for: item("a.gif"), hasAlpha: false, canWrite: all) == .jpg)
    }

    /// A Mac without an HEVC (Intel) or AVIF (older macOS) encoder never offers or attempts those outputs.
    @Test func unwritableImageFormatsFallBack() {
        let noHEICorAVIF: (OutputFormat) -> Bool = { $0 != .heic && $0 != .avif }
        let table = ConversionMatrix.table(for: .image, canWriteImage: noHEICorAVIF)
        #expect(table == [.jpg, .png, .webp, .tiff, .bmp, .gif, .ico, .pdf])
        #expect(ImageCompressor.outputFormat(for: item("a.heic"), hasAlpha: false, canWrite: noHEICorAVIF) == .jpg)
        #expect(ImageCompressor.outputFormat(for: item("a.avif"), hasAlpha: true, canWrite: noHEICorAVIF) == .png)
        #expect(ImageProcessor.editFormat(for: item("a.heic"), canWrite: noHEICorAVIF) == .png)
        #expect(ImageProcessor.editFormat(for: item("a.avif"), canWrite: noHEICorAVIF) == .png)
        #expect(ImageProcessor.editFormat(for: item("a.heic"), canWrite: { _ in true }) == .heic)
        for always in [OutputFormat.jpg, .png, .webp, .ico, .pdf] { #expect(ImageFile.canWrite(always)) }
        #expect(!ImageFile.canWrite(.mp4))
    }

    // MARK: Metadata

    private func contains(_ data: Data, _ text: String) -> Bool { data.range(of: Data(text.utf8)) != nil }

    @Test func stripAll() async throws {
        let src = Fixtures.jpegWithMetadata(in: root)
        let before = Fixtures.bytes(src)
        let secrets = ["XMP Secret", "IPTC Secret", "SN-12345", "OrbitCam", "2024:05:06 07:08:09"]
        for secret in secrets { #expect(contains(before, secret), "fixture should contain \(secret)") }
        let out = try #require(try await run([src], .tool(.metadata, .metadataStripAll)).outputs.first)
        let d = Fixtures.bytes(out)
        for secret in secrets { #expect(!contains(d, secret), "stripped file still contains \(secret)") }
        let f = ImageMetadata.read(out)
        #expect(f.first { $0.key == .gpsLatitude } == nil && f.first { $0.key == .gpsLongitude } == nil)
        #expect(f.first { $0.key == .cameraMake } == nil && f.first { $0.key == .serialNumber } == nil)
        #expect(f.first { $0.key == .artist }?.value == "")
        #expect(out.lastPathComponent.hasSuffix("-clean.jpg"))
        #expect(Fixtures.size(out) == CGSize(width: 64, height: 48))
        #expect(Fixtures.bytes(src) == before)
    }

    @Test func stripAllKeepsPixels() async throws {
        let src = Fixtures.jpegWithMetadata(in: root)
        let out = try #require(try await run([src], .tool(.metadata, .metadataStripAll)).outputs.first)
        #expect(Fixtures.decodedPixels(out) == Fixtures.decodedPixels(src))
        let edited = try #require(try await run([src], .tool(.metadata, nil), parameters: .metadata(["artist": "Kevo"])).outputs.first)
        #expect(Fixtures.decodedPixels(edited) == Fixtures.decodedPixels(src))
    }

    /// Nearly every camera JPEG has an Orientation tag; strip-all must stay lossless for it, keep it
    /// upright, and drop the EXIF thumbnail (a small copy of the photo inside APP1).
    @Test(arguments: [6, 1])
    func stripAllKeepsOrientationLosslessly(orientation: Int) async throws {
        let src = Fixtures.jpegWithMetadata(in: root, orientation: orientation, thumbnail: true)
        #expect(startOfImageCount(Fixtures.bytes(src)) == 2, "fixture should embed a thumbnail")
        let out = try #require(try await run([src], .tool(.metadata, .metadataStripAll)).outputs.first)
        #expect(Fixtures.decodedPixels(out) == Fixtures.decodedPixels(src))
        let kept = ImageFile.properties(out)[kCGImagePropertyOrientation] as? Int ?? 1
        #expect(kept == orientation)
        let d = Fixtures.bytes(out)
        #expect(startOfImageCount(d) == 1, "the EXIF thumbnail survived")
        for secret in ["XMP Secret", "IPTC Secret", "SN-12345", "OrbitCam", "2024:05:06 07:08:09"] {
            #expect(!contains(d, secret), "stripped file still contains \(secret)")
        }
        #expect(ImageFile.properties(out)[kCGImagePropertyGPSDictionary] == nil)
    }

    /// JPEG start-of-image markers (FF D8 FF): 1 for a plain JPEG, 2 with an embedded thumbnail.
    private func startOfImageCount(_ d: Data) -> Int {
        let b = [UInt8](d)
        guard b.count > 2 else { return 0 }
        return (0..<(b.count - 2)).filter { b[$0] == 0xFF && b[$0 + 1] == 0xD8 && b[$0 + 2] == 0xFF }.count
    }

    @Test func stripAllPNGText() async throws {
        let src = Fixtures.pngWithText(in: root)
        #expect(contains(Fixtures.bytes(src), "PNG Secret") && contains(Fixtures.bytes(src), "PNG Description Secret"))
        let out = try #require(try await run([src], .tool(.metadata, .metadataStripAll)).outputs.first)
        let d = Fixtures.bytes(out)
        #expect(!contains(d, "PNG Secret") && !contains(d, "PNG Description Secret"))
        #expect(out.pathExtension == "png" && Fixtures.size(out) == CGSize(width: 40, height: 30))
        #expect(Fixtures.decodedPixels(out) == Fixtures.decodedPixels(src))
    }

    @Test func stripLocationKeepsCamera() async throws {
        let out = try #require(try await run([Fixtures.jpegWithMetadata(in: root)], .tool(.metadata, .metadataStripLocation)).outputs.first)
        let f = ImageMetadata.read(out)
        #expect(f.first { $0.key == .gpsLatitude } == nil && f.first { $0.key == .gpsLongitude } == nil)
        #expect(f.first { $0.key == .cameraMake }?.value == "OrbitCam")
        let d = Fixtures.bytes(out)
        #expect(contains(d, "SN-12345") && contains(d, "OrbitCam"))
    }

    @Test func readsFields() {
        let f = ImageMetadata.read(Fixtures.jpegWithMetadata(in: root))
        func value(_ k: MetadataKey) -> String? { f.first { $0.key == k }?.value }
        #expect(value(.cameraMake) == "OrbitCam" && value(.cameraModel) == "X1")
        #expect(value(.serialNumber) == "SN-12345")
        #expect(value(.dateTaken) == "2024:05:06 07:08:09")
        #expect(Double(value(.gpsLatitude) ?? "") == 37.33)
        #expect(Double(value(.gpsLongitude) ?? "") == -122.03)
        #expect(value(.pixelSize) == "64 × 48")
        #expect(f.first { $0.key == .dateTaken }?.editable == true)
        #expect(f.first { $0.key == .cameraMake }?.editable == false)
    }

    @Test func editArtist() async throws {
        let src = Fixtures.jpegWithMetadata(in: root)
        let r = try await run([src], .tool(.metadata, nil), parameters: .metadata(["artist": "Kevo", "copyright": "(c) Kevo"]))
        let out = try #require(r.outputs.first)
        #expect(out.lastPathComponent.hasSuffix("-edited.jpg"))
        let f = ImageMetadata.read(out)
        #expect(f.first { $0.key == .artist }?.value == "Kevo")
        #expect(f.first { $0.key == .copyright }?.value == "(c) Kevo")
        #expect(f.first { $0.key == .cameraMake }?.value == "OrbitCam")
    }

    @Test func editEmptyRemoves() async throws {
        let src = Fixtures.jpegWithMetadata(in: root)
        let r = try await run([src], .tool(.metadata, nil),
                              parameters: .metadata(["dateTaken": "2020:01:02 03:04:05", "artist": "A"]))
        let mid = try #require(r.outputs.first)
        #expect(ImageMetadata.read(mid).first { $0.key == .dateTaken }?.value == "2020:01:02 03:04:05")
        let r2 = try await run([mid], .tool(.metadata, nil), parameters: .metadata(["dateTaken": "", "artist": ""]))
        let f = ImageMetadata.read(try #require(r2.outputs.first))
        #expect(f.first { $0.key == .dateTaken }?.value == "")
        #expect(f.first { $0.key == .artist }?.value == "")
    }

    @Test func mapLink() {
        #expect(ImageMetadata.mapLink(lat: 37.33, lon: -122.03).absoluteString == "https://maps.apple.com/?ll=37.33,-122.03")
    }

    // MARK: QR

    @Test func readsQR() async throws {
        let r = try await run([Fixtures.qr("https://example.com/orbit", in: root)], .tool(.readQR, nil))
        #expect(r.clipboardText == "https://example.com/orbit" && r.outputs.isEmpty)
        #expect(r.summary == "Copied: https://example.com/orbit")
    }

    @Test func readsSeveralQR() async throws {
        let a = Fixtures.qr("alpha", in: root, name: "a.png")
        let b = Fixtures.qr("beta", in: root, name: "b.png")
        let r = try await run([a, b], .tool(.readQR, nil))
        #expect(r.clipboardText == "alpha\nbeta")
        #expect(r.summary == "Copied 2 QR codes")
    }

    @Test func noQRErrors() async throws {
        let plain = Fixtures.image("plain.png", w: 200, h: 200, in: root)
        await #expect(throws: OrbitError.unsupported("No QR code found.")) {
            try await self.run([plain], .tool(.readQR, nil))
        }
    }

    // MARK: Collage

    private func collageSources(_ n: Int) -> [URL] {
        (0..<n).map { Fixtures.image("c\($0).png", w: 300 + $0 * 20, h: 200, in: root) }
    }

    @Test func collageSizes() throws {
        #expect(try CollageMaker.make(collageSources(4), to: root.appending(path: "c.jpg")) == CGSize(width: 2048, height: 2048))
        #expect(try CollageMaker.make(collageSources(5), to: root.appending(path: "c5.jpg")) == CGSize(width: 2048, height: 1368))
        #expect(Fixtures.size(root.appending(path: "c5.jpg")) == CGSize(width: 2048, height: 1368))
    }

    @Test func collageEndToEnd() async throws {
        let r = try await run(collageSources(3), .tool(.collage, nil))
        let out = try #require(r.outputs.first)
        #expect(r.outputs.count == 1 && out.lastPathComponent == "c0-collage.jpg")
        #expect(Fixtures.size(out).width == 2048)
        // Gutter pixel is white.
        #expect(Fixtures.pixel(out, x: 4, y: 4).isWhite)
        // Cell is filled (not white).
        #expect(!Fixtures.pixel(out, x: 500, y: 500).isWhite)
    }

    @Test func collageAlphaMakesPNG() async throws {
        var urls = collageSources(2)
        urls.append(Fixtures.image("alpha.png", w: 100, h: 100, alpha: true, in: root))
        let out = try #require(try await run(urls, .tool(.collage, nil)).outputs.first)
        #expect(out.pathExtension == "png")
    }
}
