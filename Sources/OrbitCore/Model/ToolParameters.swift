import CoreGraphics
import Foundation

public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }
}

/// One markup mark. Coordinates are image pixels with the origin at top left.
public enum MarkupElement: Equatable, Sendable {
    case arrow(from: CGPoint, to: CGPoint, color: RGBA, width: CGFloat)
    case box(CGRect, color: RGBA, width: CGFloat)
    case text(String, at: CGPoint, size: CGFloat, color: RGBA)
    case marker([CGPoint], color: RGBA, width: CGFloat)
    case step(Int, at: CGPoint, color: RGBA)
    case blackout(CGRect)
}

/// Markup for one image. Coordinates are image pixels with the origin at top left.
public struct MarkupDocument: Equatable, Sendable {
    public var elements: [MarkupElement]
    public var crop: CGRect?
    public var resize: CGSize?

    public init(elements: [MarkupElement] = [], crop: CGRect? = nil, resize: CGSize? = nil) {
        self.elements = elements
        self.crop = crop
        self.resize = resize
    }
}

public struct AdjustSettings: Equatable, Sendable {
    public var auto: Bool
    public var exposure: Double
    public var contrast: Double
    public var saturation: Double
    public var warmth: Double
    public var blackAndWhite: Bool
    public var quarterTurns: Int
    public var flipHorizontal: Bool
    public var flipVertical: Bool

    public init(auto: Bool = false, exposure: Double = 0, contrast: Double = 1, saturation: Double = 1,
                warmth: Double = 0, blackAndWhite: Bool = false, quarterTurns: Int = 0,
                flipHorizontal: Bool = false, flipVertical: Bool = false) {
        self.auto = auto
        self.exposure = exposure
        self.contrast = contrast
        self.saturation = saturation
        self.warmth = warmth
        self.blackAndWhite = blackAndWhite
        self.quarterTurns = quarterTurns
        self.flipHorizontal = flipHorizontal
        self.flipVertical = flipVertical
    }
}

public enum BackgroundStyle: Equatable, Sendable {
    case solid(RGBA)
    case gradient(RGBA, RGBA)
    case blur(radius: Double)
}

/// Rectangles to redact on one page. Page space, in points, with the origin at bottom left.
public struct PDFRedaction: Equatable, Sendable {
    public var pageIndex: Int
    public var rects: [CGRect]

    public init(pageIndex: Int, rects: [CGRect]) {
        self.pageIndex = pageIndex
        self.rects = rects
    }
}

/// One page of an organized PDF: which source page, and how many quarter turns it gets.
public struct PageOp: Equatable, Sendable {
    public var sourceIndex: Int
    public var quarterTurns: Int

    public init(sourceIndex: Int, quarterTurns: Int = 0) {
        self.sourceIndex = sourceIndex
        self.quarterTurns = quarterTurns
    }
}

/// What an editor (or a preset needing extra input) hands to a job.
public enum ToolParameters: Equatable, Sendable {
    case none
    case markup(MarkupDocument)
    case adjust(AdjustSettings)
    case background(BackgroundStyle)
    case timeRange(ClosedRange<Double>)
    case cropRect(CGRect)
    case splitPoints([Double])
    case time(Double)
    case bleepRanges([ClosedRange<Double>])
    case pdfRedactions([PDFRedaction])
    case pdfPages([PageOp])
    case pdfRanges([ClosedRange<Int>])
    case metadata([String: String])
    case compress(CompressTarget)
    case folder(URL)
}
