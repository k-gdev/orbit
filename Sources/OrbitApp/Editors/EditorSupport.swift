import AppKit
import ImageIO
import OrbitCore
import SwiftUI

/// What the editors share: the 1024 px preview proxy, color conversion, and the small controls drawn in
/// SwiftUI (so they match the accent-coloured sliders and also render in headless snapshots).
enum EditorStyle {
    /// Long edge of the previews every editor renders.
    static let proxyLongEdge = 1024
}

/// An image opened for editing: a preview proxy and the true pixel size the job will work on.
struct EditorImage: @unchecked Sendable {
    /// At most `EditorStyle.proxyLongEdge` px on the long edge, orientation applied.
    let proxy: CGImage
    /// Pixel size of the full image, orientation applied (what `ImageFile.loadOriented` returns).
    let pixelSize: CGSize

    /// `proxy` pixels per full-image pixel (1 unless the image is bigger than the proxy).
    var proxyScale: Double { Double(proxy.width) / Double(pixelSize.width) }

    static func load(_ url: URL) throws -> EditorImage {
        if url.pathExtension.lowercased() != "svg",
           let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
           w > 0, h > 0 {
            let turned = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
            let size = turned ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: EditorStyle.proxyLongEdge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let proxy = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return EditorImage(proxy: proxy, pixelSize: size)
            }
        }
        // SVG and anything ImageIO can't thumbnail: load it whole and shrink.
        return try make(from: try ImageFile.loadOriented(url))
    }

    static func make(from full: CGImage) throws -> EditorImage {
        let size = CGSize(width: full.width, height: full.height)
        let target = EditorGeometry.proxySize(for: size, longEdge: EditorStyle.proxyLongEdge)
        guard target != size else { return EditorImage(proxy: full, pixelSize: size) }
        guard let ctx = CGContext(data: nil, width: Int(target.width), height: Int(target.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw OrbitError.unsupported("Orbit can't read this image.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(full, in: CGRect(origin: .zero, size: target))
        guard let proxy = ctx.makeImage() else { throw OrbitError.unsupported("Orbit can't read this image.") }
        return EditorImage(proxy: proxy, pixelSize: size)
    }

    /// True when some pixel of the proxy is not fully opaque.
    var hasTransparency: Bool {
        guard ImageFile.hasAlpha(proxy),
              let ctx = CGContext(data: nil, width: proxy.width, height: proxy.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        ctx.draw(proxy, in: CGRect(x: 0, y: 0, width: proxy.width, height: proxy.height))
        let bytes = data.bindMemory(to: UInt8.self, capacity: ctx.bytesPerRow * proxy.height)
        for y in 0..<proxy.height {
            let row = y * ctx.bytesPerRow
            for x in 0..<proxy.width where bytes[row + x * 4 + 3] != 255 { return true }
        }
        return false
    }
}

extension RGBA {
    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.red
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: 1)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

/// Renders previews off the main thread. Requests made while one is rendering collapse into the latest one.
@MainActor
final class PreviewLoop {
    private struct Outcome: @unchecked Sendable { let result: Result<CGImage, Error> }

    private var rendering = false
    private var pending: (@Sendable () throws -> CGImage)?
    private let deliver: (Result<CGImage, Error>) -> Void

    /// `deliver` gets every finished render, or the error it failed with (so a failure is shown, not swallowed).
    init(deliver: @escaping (Result<CGImage, Error>) -> Void) { self.deliver = deliver }

    func submit(_ work: @escaping @Sendable () throws -> CGImage) {
        pending = work
        guard !rendering else { return }
        rendering = true
        Task {
            while let work = pending {
                pending = nil
                let outcome = await Task.detached(priority: .userInitiated) { Outcome(result: Result { try work() }) }.value
                deliver(outcome.result)
            }
            rendering = false
        }
    }
}

/// What the preview area says when a render fails.
struct PreviewErrorBanner: View {
    let message: String

    var body: some View {
        Text(message)
            .font(.system(size: 12, weight: .medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.regularMaterial))
            .padding(10)
    }
}

// MARK: Controls

/// An accent-coloured slider. Drawn in SwiftUI.
struct OrbitSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double?

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width - Self.knob, 1)
            let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.14)).frame(height: 4)
                Capsule().fill(OrbitTheme.accent).frame(width: Self.knob / 2 + width * fraction, height: 4)
                Circle().fill(Color.white)
                    .frame(width: Self.knob, height: Self.knob)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: width * fraction)
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - Self.knob / 2) / width, 0), 1)
                var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
                if let step { v = (v / step).rounded() * step }
                value = min(max(v, range.lowerBound), range.upperBound)
            })
        }
        .frame(height: 22)
    }

    private static let knob: CGFloat = 20
}

/// A pill switch. Drawn in SwiftUI.
struct OrbitSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule().fill(isOn ? OrbitTheme.accent : Color.primary.opacity(0.18))
                .frame(width: 38, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(Color.white).frame(width: 18, height: 18).padding(2)
                        .shadow(color: .black.opacity(0.2), radius: 1, y: 1)
                }
                .animation(.easeOut(duration: 0.12), value: isOn)
        }
        .buttonStyle(.plain)
    }
}

/// A round color well. Live it is the system color picker; in snapshots (flat rendering) a plain disc.
struct OrbitColorWell: View {
    @Binding var color: Color
    var help: String

    @Environment(\.glassRendering) private var rendering

    var body: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
            Circle().fill(color).padding(4)
            Circle().stroke(Color.white.opacity(0.8), lineWidth: 1.5).padding(4)
            if rendering == .live {
                ColorPicker("", selection: $color, supportsOpacity: false)
                    .labelsHidden()
                    .opacity(0.02)
            }
        }
        .frame(width: 28, height: 28)
        .help(help)
    }
}

/// A small rounded text button used for choices (aspect ratios, modes).
struct ChoiceChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.primary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? OrbitTheme.accent : Color.primary.opacity(0.09)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A symbol over a caption, the editors' tool button.
struct ToolButton: View {
    let symbol: String
    let title: String
    let selected: Bool
    var enabled = true
    var expands = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(height: 18)
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(selected ? Color.white : Color.primary)
            .frame(minWidth: 52, maxWidth: expands ? .infinity : nil).padding(.vertical, 6).padding(.horizontal, 4)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? OrbitTheme.accent : Color.primary.opacity(0.07)))
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A numeric text field (live), or a plain box with the number (snapshots).
struct NumberField: View {
    @Binding var value: Double
    var width: CGFloat = 64

    @Environment(\.glassRendering) private var rendering

    private static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        f.usesGroupingSeparator = false
        return f
    }()

    var body: some View {
        Group {
            if rendering == .live {
                TextField("", value: $value, formatter: Self.formatter)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
            } else {
                Text(Self.formatter.string(from: NSNumber(value: value)) ?? "").frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .font(.system(size: 13).monospacedDigit())
        .padding(.horizontal, 8).padding(.vertical, 5)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(0.08)))
    }
}

/// Shows a preview image fitted in its space, with a spinner while it loads.
struct PreviewImage: View {
    let image: CGImage?

    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fit)
        } else {
            ProgressView().controlSize(.small)
        }
    }
}
