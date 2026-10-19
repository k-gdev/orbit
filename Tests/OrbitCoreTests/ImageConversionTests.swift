import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import OrbitCore

@Suite final class ImageConversionTests {
    let root = Fixtures.tempDir()
    let fallback: URL

    init() throws {
        fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: false)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    private func run(_ urls: [URL], _ action: SliceAction, options: JobOptions = JobOptions()) async throws -> JobResult {
        let rootPath = root.path + "/"
        let runner = JobRunner(
            processors: ProcessorRegistry.standard(capabilities: Fixtures.caps), capabilities: Fixtures.caps,
            fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
        return try await runner.run(JobRequest(items: urls.map(DroppedItem.init(url:)), action: action, options: options),
                                    progress: { _ in })
    }

    private func run(_ names: [String], _ action: SliceAction) async throws -> JobResult {
        let sizes = ["img10.png": (300, 100), "img2.png": (200, 100), "img1.png": (100, 100)]
        let urls = names.map { n in Fixtures.image(n, w: sizes[n]!.0, h: sizes[n]!.1, in: root) }
        return try await run(urls, action)
    }

    private func convertURL(_ url: URL, to f: OutputFormat, options: JobOptions = JobOptions()) async throws -> URL {
        let r = try await run([url], .convert(f), options: options)
        #expect(r.failures.isEmpty)
        return try #require(r.outputs.first)
    }

    private func convert(_ name: String, w: Int, h: Int, alpha: Bool = false, noise: Bool = false,
                         to f: OutputFormat, options: JobOptions = JobOptions()) async throws -> URL {
        try await convertURL(Fixtures.image(name, w: w, h: h, alpha: alpha, noise: noise, in: root), to: f, options: options)
    }

    private func bytes(_ url: URL) throws -> Int {
        try #require(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
    }

    @Test(arguments: [OutputFormat.jpg, .heic, .webp, .tiff, .avif, .bmp, .gif])
    func pngConverts(to f: OutputFormat) async throws {
        let out = try await convert("a.png", w: 120, h: 80, to: f)
        #expect(Fixtures.size(out) == CGSize(width: 120, height: 80))
        #expect(out.pathExtension == f.fileExtension)
        #expect(out.lastPathComponent == "a-converted.\(f.fileExtension)")
    }

    @Test func pngToPDFOnePage() async throws {
        #expect(PDFDocument(url: try await convert("a.png", w: 120, h: 80, to: .pdf))?.pageCount == 1)
    }

    @Test func icoCapped() async throws {
        #expect(Fixtures.size(try await convert("a.png", w: 1000, h: 500, to: .ico)) == CGSize(width: 256, height: 128))
    }

    @Test func jpegFlattensAlpha() async throws {
        let out = try await convert("t.png", w: 50, h: 50, alpha: true, to: .jpg)
        #expect(Fixtures.pixel(out, x: 0, y: 0).isWhite)
    }

    @Test func orientationBaked() async throws {
        let src = Fixtures.jpegWithOrientation(6, w: 200, h: 100, in: root)
        #expect(Fixtures.size(try await convertURL(src, to: .png)) == CGSize(width: 100, height: 200))
    }

    @Test func svgRasterized() async throws {
        #expect(Fixtures.size(try await convertURL(Fixtures.svg(w: 100, h: 50, in: root), to: .png)) == CGSize(width: 1024, height: 512))
    }

    @Test func webpBytes() async throws {
        let d = try Data(contentsOf: try await convert("a.png", w: 120, h: 80, to: .webp))
        #expect(d.prefix(4) == Data("RIFF".utf8) && d[8..<12] == Data("WEBP".utf8))
    }

    @Test func manyImagesOnePDFNaturalOrder() async throws {
        let r = try await run(["img10.png", "img2.png", "img1.png"], .convert(.pdf))
        let pdf = try #require(PDFDocument(url: r.outputs[0]))
        #expect(r.outputs.count == 1)
        #expect(r.outputs[0].lastPathComponent == "img1-combined.pdf")
        #expect((0..<3).map { pdf.page(at: $0)!.bounds(for: .mediaBox).width } == [100, 200, 300])
    }

    @Test func qualityMatters() async throws {
        let noisy = Fixtures.image("n.png", w: 200, h: 200, noise: true, in: root)
        let low = try await convertURL(noisy, to: .jpg, options: JobOptions(jpegQuality: 0.3))
        let lowSize = try bytes(low)
        try FileManager.default.removeItem(at: low)
        let high = try await convertURL(noisy, to: .jpg, options: JobOptions(jpegQuality: 0.95))
        #expect(lowSize < (try bytes(high)))
    }

    @Test func webpQualityMatters() async throws {
        let noisy = Fixtures.image("n.png", w: 200, h: 200, noise: true, in: root)
        let low = try await convertURL(noisy, to: .webp, options: JobOptions(webpQuality: 0.2))
        let lowSize = try bytes(low)
        try FileManager.default.removeItem(at: low)
        let high = try await convertURL(noisy, to: .webp, options: JobOptions(webpQuality: 0.95))
        #expect(lowSize < (try bytes(high)))
    }

    @Test func webpKeepsAlpha() async throws {
        let out = try await convert("t.png", w: 20, h: 20, alpha: true, to: .webp)
        #expect(Fixtures.pixel(out, x: 0, y: 0).a < 0.05)
    }

    @Test func webpKeepsSemiTransparentColour() async throws {
        // 50% alpha red, written as a PNG with straight (non-premultiplied) data via CoreGraphics.
        let ctx = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 128.0 / 255))
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let src = root.appending(path: "half.png")
        try ImageFile.write(try #require(ctx.makeImage()), to: src, format: .png, quality: nil, properties: nil)
        let out = try await convertURL(src, to: .webp, options: JobOptions(webpQuality: 1))
        let p = Fixtures.pixel(out, x: 4, y: 4)
        #expect(abs(p.a - 128.0 / 255) < 0.05)
        #expect(p.r > 0.9 && p.g < 0.1 && p.b < 0.1)
    }

    @Test func webpSourceReadsBack() async throws {
        let webp = try await convert("a.png", w: 64, h: 32, to: .webp)
        let back = try await convertURL(webp, to: .png)
        #expect(Fixtures.size(back) == CGSize(width: 64, height: 32))
    }

    @Test func pdfPageSizeFollowsDPI() async throws {
        // 200 px at 144 DPI is 100 pt.
        let plain = Fixtures.image("src.png", w: 200, h: 100, in: root)
        let image = try ImageFile.loadOriented(plain)
        let dpi144 = root.appending(path: "dpi144.png")
        try ImageFile.write(image, to: dpi144, format: .png, quality: nil,
                            properties: [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144])
        let out = root.appending(path: "dpi.pdf")
        try ImagesToPDF.make([dpi144, plain], output: out)
        let pdf = try #require(PDFDocument(url: out))
        #expect(pdf.page(at: 0)?.bounds(for: .mediaBox).size == CGSize(width: 100, height: 50))
        #expect(pdf.page(at: 1)?.bounds(for: .mediaBox).size == CGSize(width: 200, height: 100))
    }

    @Test func sourceIsUntouched() async throws {
        let src = Fixtures.image("keep.png", w: 30, h: 30, in: root)
        let before = try Data(contentsOf: src)
        _ = try await convertURL(src, to: .jpg)
        #expect(try Data(contentsOf: src) == before)
    }

    @Test func summaryHintForIcoDownscale() async throws {
        let src = Fixtures.image("wide.png", w: 1000, h: 500, in: root)
        let hint = try ImageConverter.convert(src, to: .ico, output: root.appending(path: "w.ico"), options: JobOptions())
        #expect(hint == .dimensions(from: CGSize(width: 1000, height: 500), to: CGSize(width: 256, height: 128)))
    }
}
