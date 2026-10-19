import CoreGraphics
import Foundation
import Testing
@testable import OrbitCore

@Suite final class ImageEditTests {
    let root = Fixtures.tempDir()
    deinit { try? FileManager.default.removeItem(at: root) }

    private func px(_ i: CGImage, _ x: Int, _ y: Int) -> EditPixel { Fixtures.editPixel(i, x, y) }
    private let red = RGBA(r: 1, g: 0, b: 0, a: 1)

    // MARK: Markup

    @Test func blackoutIsBurnedIn() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
                                            MarkupDocument(elements: [.blackout(CGRect(x: 10, y: 10, width: 50, height: 50))]))
        #expect(px(img, 30, 30) == .black)
        #expect(px(img, 100, 50) == .white)
    }

    @Test func blackoutUsesTopLeftOrigin() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
                                            MarkupDocument(elements: [.blackout(CGRect(x: 0, y: 0, width: 20, height: 20))]))
        #expect(px(img, 5, 5) == .black)
        #expect(px(img, 5, 95) == .white)
    }

    @Test func fractionalBlackoutCoversEveryTouchedPixelExactly() throws {
        // x 10.5..<60.5, y 10.25..<40.75: the integral rect is x 10..<61, y 10..<41.
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
                                            MarkupDocument(elements: [.blackout(CGRect(x: 10.5, y: 10.25, width: 50, height: 30.5))]))
        #expect(px(img, 10, 20) == .black)
        #expect(px(img, 60, 20) == .black)
        #expect(px(img, 30, 10) == .black)
        #expect(px(img, 30, 40) == .black)
        #expect(px(img, 9, 20) == .white)
        #expect(px(img, 61, 20) == .white)
        #expect(px(img, 30, 9) == .white)
        #expect(px(img, 30, 41) == .white)
    }

    @Test func cropThenResize() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
                                            MarkupDocument(crop: CGRect(x: 0, y: 0, width: 100, height: 50),
                                                           resize: CGSize(width: 50, height: 25)))
        #expect(img.width == 50 && img.height == 25)
    }

    @Test func cropKeepsTheMarkedRegion() throws {
        let doc = MarkupDocument(elements: [.blackout(CGRect(x: 100, y: 0, width: 50, height: 50))],
                                 crop: CGRect(x: 100, y: 0, width: 100, height: 50))
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100), doc)
        #expect(img.width == 100 && img.height == 50)
        #expect(px(img, 10, 10) == .black)
        #expect(px(img, 80, 10) == .white)
    }

    @Test func arrowDrawsSomething() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
            MarkupDocument(elements: [.arrow(from: CGPoint(x: 10, y: 10), to: CGPoint(x: 150, y: 80), color: red, width: 6)]))
        #expect(Fixtures.editNonWhiteCount(img) > 100)
    }

    @Test func boxMarkerTextAndStepDraw() throws {
        let cases: [MarkupElement] = [
            .box(CGRect(x: 20, y: 20, width: 100, height: 50), color: red, width: 4),
            .marker([CGPoint(x: 10, y: 10), CGPoint(x: 100, y: 60), CGPoint(x: 150, y: 20)], color: red, width: 8),
            .text("Hello", at: CGPoint(x: 20, y: 30), size: 30, color: red),
            .step(3, at: CGPoint(x: 100, y: 50), color: red),
        ]
        for element in cases {
            let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100), MarkupDocument(elements: [element]))
            #expect(Fixtures.editNonWhiteCount(img) > 50, "\(element)")
        }
    }

    @Test func stepIsAFilledCircleWithAWhiteNumber() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(200, 100),
                                            MarkupDocument(elements: [.step(1, at: CGPoint(x: 100, y: 50), color: red)]))
        #expect(px(img, 100 - 15, 50) == .red)       // inside the 36 px circle, left of the digit
        #expect(px(img, 100 - 25, 50) == .white)      // outside it
    }

    @Test func opaqueSourcesStayOpaque() throws {
        let img = try MarkupRenderer.render(Fixtures.editWhite(40, 40),
                                            MarkupDocument(elements: [.blackout(CGRect(x: 0, y: 0, width: 5, height: 5))]))
        #expect(Fixtures.editMinAlpha(img) == 1)
    }

    // MARK: Adjust

    @Test func adjustIdentity() throws {
        let photo = Fixtures.editPhoto(120, 80)
        #expect(Fixtures.editMaxDiff(try AdjustRenderer.render(photo, AdjustSettings()), photo) <= 2)
    }

    @Test func adjustRotate() throws {
        var s = AdjustSettings()
        s.quarterTurns = 1
        let o = try AdjustRenderer.render(Fixtures.editWhite(200, 100), s)
        #expect(o.width == 100 && o.height == 200)
    }

    @Test func rotateClockwiseMovesTopLeftToTopRight() throws {
        let src = Fixtures.editImage(40, 20) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        var s = AdjustSettings()
        s.quarterTurns = 1
        let o = try AdjustRenderer.render(src, s)
        #expect(px(o, 15, 5) == .red)
        #expect(px(o, 5, 5) == .white)
        s.quarterTurns = -1   // counter-clockwise
        #expect(px(try AdjustRenderer.render(src, s), 5, 35) == .red)
    }

    @Test func flipsMirrorThePixels() throws {
        let src = Fixtures.editImage(40, 20) { ctx in
            ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 20))
            ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: 10, height: 10))
        }
        var s = AdjustSettings()
        s.flipHorizontal = true
        #expect(px(try AdjustRenderer.render(src, s), 35, 5) == .red)
        s = AdjustSettings()
        s.flipVertical = true
        #expect(px(try AdjustRenderer.render(src, s), 5, 15) == .red)
    }

    @Test func adjustMono() throws {
        var s = AdjustSettings()
        s.blackAndWhite = true
        let p = px(try AdjustRenderer.render(Fixtures.editColorful(60, 40), s), 20, 20)
        #expect(abs(p.r - p.g) < 0.01 && abs(p.g - p.b) < 0.01)
    }

    @Test func exposureWarmthAndSaturationMoveTheirChannels() throws {
        let base = Fixtures.editSolid(40, 40, r: 0.4, g: 0.4, b: 0.4)
        var s = AdjustSettings()
        s.exposure = 1
        #expect(px(try AdjustRenderer.render(base, s), 5, 5).g > 0.5)
        s = AdjustSettings()
        s.warmth = 1
        let warm = px(try AdjustRenderer.render(base, s), 5, 5)
        #expect(warm.r > warm.b)
        s.warmth = -1
        let cool = px(try AdjustRenderer.render(base, s), 5, 5)
        #expect(cool.b > cool.r)
        s = AdjustSettings()
        s.saturation = 0
        let grey = px(try AdjustRenderer.render(Fixtures.editColorful(40, 40), s), 5, 5)
        #expect(abs(grey.r - grey.b) < 0.02)
    }

    @Test func autoAdjustRuns() throws {
        var s = AdjustSettings()
        s.auto = true
        let o = try AdjustRenderer.render(Fixtures.editPhoto(120, 80), s)
        #expect(o.width == 120 && o.height == 80)
    }

    // MARK: Background

    @Test func solidBackground() throws {
        let subject = Fixtures.editSquareOnTransparent(100)
        let o = try BackgroundComposer.compose(subject: subject, original: nil, style: .solid(red))
        #expect(px(o, 0, 0) == .red)
        #expect(px(o, 50, 50) == .blue)
    }

    @Test func gradientRunsTopToBottom() throws {
        let o = try BackgroundComposer.compose(subject: Fixtures.editSquareOnTransparent(100), original: nil,
                                               style: .gradient(RGBA(r: 1, g: 0, b: 0, a: 1), RGBA(r: 0, g: 1, b: 0, a: 1)))
        #expect(px(o, 2, 1).r > 0.9 && px(o, 2, 1).g < 0.1)
        #expect(px(o, 2, 98).g > 0.9 && px(o, 2, 98).r < 0.1)
        #expect(Fixtures.editMinAlpha(o) == 1)
    }

    @Test func blurBackgroundOpaque() throws {
        let o = try BackgroundComposer.compose(subject: Fixtures.editSquareOnTransparent(100),
                                               original: Fixtures.editPhoto(100, 100), style: .blur(radius: 12))
        #expect(Fixtures.editMinAlpha(o) == 1)
        #expect(o.width == 100 && o.height == 100)
        #expect(px(o, 50, 50) == .blue)
        #expect(px(o, 2, 50) != .white)
    }

    // MARK: Through the job runner

    private func run(_ url: URL, _ action: SliceAction, _ parameters: ToolParameters) async throws -> JobResult {
        let fallback = root.appending(path: "fallback", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        let rootPath = root.path + "/"
        let runner = JobRunner(
            processors: ProcessorRegistry.standard(capabilities: Fixtures.caps), capabilities: Fixtures.caps,
            fallbackFolder: fallback,
            trash: { url in
                guard url.path.hasPrefix(rootPath) else { throw CocoaError(.fileWriteNoPermission) }
                try FileManager.default.removeItem(at: url)
            })
        return try await runner.run(JobRequest(items: [DroppedItem(url: url)], action: action, parameters: parameters),
                                    progress: { _ in })
    }

    @Test func markupJobWritesEditedFileInSourceFormat() async throws {
        let src = Fixtures.image("shot.jpg", w: 200, h: 100, in: root)
        let doc = MarkupDocument(elements: [.blackout(CGRect(x: 0, y: 0, width: 100, height: 100))])
        let r = try await run(src, .tool(.markup, nil), .markup(doc))
        let out = try #require(r.outputs.first)
        #expect(out.lastPathComponent == "shot-edited.jpg")
        #expect(Fixtures.pixel(out, x: 20, y: 20).r < 0.05)
        #expect(Fixtures.size(out) == CGSize(width: 200, height: 100))
    }

    @Test func markupOnSVGBecomesPNG() async throws {
        let src = Fixtures.svg(w: 80, h: 40, in: root)
        let r = try await run(src, .tool(.markup, nil), .markup(MarkupDocument()))
        #expect(try #require(r.outputs.first).lastPathComponent == "shape-edited.png")
    }

    @Test func adjustJobWritesAdjustedFile() async throws {
        let src = Fixtures.image("pic.png", w: 200, h: 100, in: root)
        var s = AdjustSettings()
        s.quarterTurns = 1
        let r = try await run(src, .tool(.adjust, nil), .adjust(s))
        let out = try #require(r.outputs.first)
        #expect(out.lastPathComponent == "pic-adjusted.png")
        #expect(Fixtures.size(out) == CGSize(width: 100, height: 200))
    }

    @Test func addBackgroundOnTransparentPNGSkipsCutout() async throws {
        let src = root.appending(path: "logo.png")
        try Fixtures.writeEditPNG(Fixtures.editSquareOnTransparent(100), to: src)
        let r = try await run(src, .tool(.addBackground, nil), .background(.solid(red)))
        let out = try #require(r.outputs.first)
        #expect(out.lastPathComponent == "logo-bg.png")
        #expect(Fixtures.pixel(out, x: 1, y: 1).r > 0.95 && Fixtures.pixel(out, x: 1, y: 1).g < 0.05)
        #expect(Fixtures.pixel(out, x: 50, y: 50).b > 0.95)
    }

    @Test func addBackgroundOnOpaqueImageCutsOutFirst() async throws {
        // A flat image has no subject, so the cut-out's error proves the cut-out ran.
        let blank = Fixtures.image("blank.png", w: 200, h: 200, in: root)
        await #expect(throws: OrbitError.noSubject) {
            try await self.run(blank, .tool(.addBackground, nil), .background(.solid(self.red)))
        }
    }

    @Test func addBackgroundWithoutStyleErrors() async throws {
        let src = Fixtures.image("a.png", w: 20, h: 20, alpha: true, in: root)
        await #expect(throws: OrbitError.self) { try await self.run(src, .tool(.addBackground, nil), .none) }
    }
}
