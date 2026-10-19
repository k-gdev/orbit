import CoreGraphics
import Testing
@testable import OrbitCore

@Suite struct EditorGeometryTests {
    private let wide = CGSize(width: 200, height: 100)
    private let square = CGSize(width: 100, height: 100)

    @Test func fit() {
        #expect(EditorGeometry.fittedRect(image: wide, in: square) == CGRect(x: 0, y: 25, width: 100, height: 50))
    }

    @Test func fitTallImageIsCenteredHorizontally() {
        #expect(EditorGeometry.fittedRect(image: CGSize(width: 100, height: 200), in: square)
            == CGRect(x: 25, y: 0, width: 50, height: 100))
    }

    @Test func fitUpscalesSmallImages() {
        #expect(EditorGeometry.fittedRect(image: CGSize(width: 10, height: 10), in: CGSize(width: 100, height: 50))
            == CGRect(x: 25, y: 0, width: 50, height: 50))
    }

    @Test func fitDegenerateSizesGiveZeroRect() {
        #expect(EditorGeometry.fittedRect(image: .zero, in: square) == .zero)
        #expect(EditorGeometry.fittedRect(image: wide, in: .zero) == .zero)
    }

    @Test func viewToImage() {
        #expect(EditorGeometry.viewToImage(CGRect(x: 0, y: 25, width: 50, height: 25), image: wide, view: square)
            == CGRect(x: 0, y: 0, width: 100, height: 50))
    }

    @Test func clamp() {
        #expect(EditorGeometry.viewToImage(CGRect(x: -10, y: 0, width: 200, height: 200), image: wide, view: square)
            == CGRect(x: 0, y: 0, width: 200, height: 100))
    }

    @Test func viewToImageRoundsToWholePixels() {
        // 1 view point = 2 image pixels here; 0.3 pt = 0.6 px.
        let r = EditorGeometry.viewToImage(CGRect(x: 10.3, y: 25.3, width: 20.2, height: 10.1), image: wide, view: square)
        #expect(r == CGRect(x: 21, y: 1, width: 40, height: 20))
    }

    @Test func viewRectOutsideImageIsEmpty() {
        let r = EditorGeometry.viewToImage(CGRect(x: 0, y: 0, width: 100, height: 10), image: wide, view: square)
        #expect(r.isEmpty)
    }

    @Test func imageToViewIsTheInverse() {
        #expect(EditorGeometry.imageToView(CGRect(x: 0, y: 0, width: 100, height: 50), image: wide, view: square)
            == CGRect(x: 0, y: 25, width: 50, height: 25))
        let back = EditorGeometry.imageToView(CGRect(x: 40, y: 20, width: 80, height: 40), image: wide, view: square)
        #expect(EditorGeometry.viewToImage(back, image: wide, view: square) == CGRect(x: 40, y: 20, width: 80, height: 40))
    }

    @Test func pointsMapBothWaysWithoutRounding() {
        let p = EditorGeometry.viewToImage(CGPoint(x: 25.25, y: 37.5), image: wide, view: square)
        #expect(p == CGPoint(x: 50.5, y: 25))
        #expect(EditorGeometry.imageToView(p, image: wide, view: square) == CGPoint(x: 25.25, y: 37.5))
    }

    @Test func aspect() {
        #expect(EditorGeometry.constrain(CGRect(x: 0, y: 0, width: 160, height: 50), aspect: 16.0 / 9.0, within: wide).size
            == CGSize(width: 160, height: 90))
    }

    @Test func constrainShrinksToStayInsideTheImage() {
        // 1:1 from (150, 0): only 50 px of width remain, so the square is 50 × 50.
        let r = EditorGeometry.constrain(CGRect(x: 150, y: 0, width: 100, height: 20), aspect: 1, within: wide)
        #expect(r == CGRect(x: 150, y: 0, width: 50, height: 50))
    }

    @Test func constrainShrinksWhenTheHeightRunsOut() {
        // 4:3 from (0, 60): 40 px of height remain, so 53 × 40 (width rounded).
        let r = EditorGeometry.constrain(CGRect(x: 0, y: 60, width: 150, height: 10), aspect: 4.0 / 3.0, within: wide)
        #expect(r.origin == CGPoint(x: 0, y: 60))
        #expect(r.height == 40)
        #expect(r.width == 53)
    }

    @Test func constrainWithoutAspectOnlyClamps() {
        let r = EditorGeometry.constrain(CGRect(x: -5, y: 90, width: 300, height: 50), aspect: nil, within: wide)
        #expect(r == CGRect(x: 0, y: 90, width: 200, height: 10))
    }

    @Test func constrainNormalizesNegativeSizes() {
        // Dragging up and to the left gives a negative-size rect.
        let r = EditorGeometry.constrain(CGRect(x: 100, y: 80, width: -60, height: -40), aspect: nil, within: wide)
        #expect(r == CGRect(x: 40, y: 40, width: 60, height: 40))
    }

    @Test func proxyNeverUpscalesAndKeepsTheAspect() {
        #expect(EditorGeometry.proxySize(for: CGSize(width: 4000, height: 3000), longEdge: 1024) == CGSize(width: 1024, height: 768))
        #expect(EditorGeometry.proxySize(for: CGSize(width: 600, height: 400), longEdge: 1024) == CGSize(width: 600, height: 400))
        #expect(EditorGeometry.proxySize(for: CGSize(width: 1000, height: 4000), longEdge: 1000) == CGSize(width: 250, height: 1000))
    }

    @Test func resizeKeepingAspectFollowsTheChangedField() {
        let original = CGSize(width: 400, height: 300)
        #expect(EditorGeometry.size(forWidth: 200, keepingAspectOf: original) == CGSize(width: 200, height: 150))
        #expect(EditorGeometry.size(forHeight: 150, keepingAspectOf: original) == CGSize(width: 200, height: 150))
        #expect(EditorGeometry.size(forWidth: 0, keepingAspectOf: original) == CGSize(width: 1, height: 1))
        #expect(EditorGeometry.size(forPercent: 50, of: original) == CGSize(width: 200, height: 150))
    }

    @Test func rotationWrapsWithinFourTurns() {
        var s = AdjustSettings()
        s.rotate(clockwise: false)
        #expect(s.quarterTurns == 3)
        s.rotate(clockwise: true)
        s.rotate(clockwise: true)
        #expect(s.quarterTurns == 1)
    }

    @Test func flipButtonsFollowThePreviewAfterAQuarterTurn() {
        var s = AdjustSettings()
        s.flipPreviewHorizontally()
        #expect(s.flipHorizontal && !s.flipVertical)
        #expect(s.isFlippedHorizontallyInPreview)

        // Turned a quarter, that same stored flip now shows as vertical, and a new horizontal flip is stored as vertical.
        s.rotate(clockwise: true)
        #expect(s.isFlippedVerticallyInPreview && !s.isFlippedHorizontallyInPreview)
        s.flipPreviewHorizontally()
        #expect(s.flipHorizontal && s.flipVertical)
        #expect(s.isFlippedHorizontallyInPreview)

        s.flipPreviewVertically()
        #expect(!s.flipHorizontal && s.flipVertical)
    }

    @Test func dragCropKeepsTheAnchorCornerFixed() {
        // Dragging from the bottom right up and left: the anchor (100, 50) stays the bottom right corner.
        let r = EditorGeometry.cropRect(anchor: CGPoint(x: 100, y: 50), to: CGPoint(x: 20, y: 10), aspect: nil, within: wide)
        #expect(r == CGRect(x: 20, y: 10, width: 80, height: 40))
    }

    @Test func dragCropWithARatioShrinksTowardTheAnchor() {
        // 1:1 toward the top left from (100, 50): at most 50 px of height remain above the anchor.
        let r = EditorGeometry.cropRect(anchor: CGPoint(x: 100, y: 50), to: CGPoint(x: 20, y: 10), aspect: 1, within: wide)
        #expect(r == CGRect(x: 50, y: 0, width: 50, height: 50))
    }

    @Test func dragCropBeyondTheImageStopsAtTheEdge() {
        let r = EditorGeometry.cropRect(anchor: CGPoint(x: 150, y: 20), to: CGPoint(x: 400, y: 300), aspect: nil, within: wide)
        #expect(r == CGRect(x: 150, y: 20, width: 50, height: 80))
    }

    @Test func centeredRectIsTheLargestOneOfTheRatio() {
        #expect(EditorGeometry.centeredRect(aspect: 1, within: wide) == CGRect(x: 50, y: 0, width: 100, height: 100))
        #expect(EditorGeometry.centeredRect(aspect: 16.0 / 9.0, within: wide) == CGRect(x: 11, y: 0, width: 178, height: 100))
        #expect(EditorGeometry.centeredRect(aspect: 4.0 / 3.0, within: CGSize(width: 100, height: 200))
            == CGRect(x: 0, y: 63, width: 100, height: 75))
    }

    // A panel measured at zero height is invisible (the fix-round-1 defect), so the size is never empty.

    @Test func panelSizeUsesTheMeasuredHeight() {
        #expect(EditorGeometry.panelSize(width: 480, measuredHeight: 612) == CGSize(width: 480, height: 612))
    }

    @Test func panelSizeNeverCollapsesToZeroHeight() {
        for measured in [0, 1, 40, -5, CGFloat.nan, CGFloat.infinity] as [CGFloat] {
            let size = EditorGeometry.panelSize(width: 480, measuredHeight: measured)
            #expect(size.width == 480)
            #expect(size.height >= EditorGeometry.minimumPanelHeight)
            #expect(size.height.isFinite)
        }
    }

    @Test func panelSizeNeverCollapsesToZeroWidth() {
        #expect(EditorGeometry.panelSize(width: 0, measuredHeight: 300).width >= 1)
    }
}
