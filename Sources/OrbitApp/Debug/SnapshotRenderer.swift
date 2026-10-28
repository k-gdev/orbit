import AppKit
import SwiftUI

/// Renders a SwiftUI view to PNG data with real AppKit drawing. Unlike `ImageRenderer` (which draws
/// yellow placeholders for toggles, pop-ups, sliders, text fields, colour wells and scroll views), this
/// hosts the view in an `NSHostingView` inside an offscreen window that is never ordered front, lets
/// SwiftUI settle for a few run loop turns, and captures it with `cacheDisplay(in:to:)` at 2x.
///
/// Glass renders `.flat` (`\.glassRendering`), since materials don't composite offscreen.
enum SnapshotRenderer {
    struct Failure: Error, CustomStringConvertible { let description: String }

    /// `size` nil: the view's own fitting size. `dark` sets both the SwiftUI colour scheme and the AppKit
    /// appearance, so native controls draw dark too.
    @MainActor
    static func png(of view: some View, size: CGSize?, dark: Bool, scale: CGFloat = 2) throws -> Data {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let root = view
            .environment(\.glassRendering, .flat)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = NSHostingView(rootView: root)
        host.appearance = appearance
        let initial = size ?? CGSize(width: max(host.fittingSize.width, 1), height: max(host.fittingSize.height, 1))
        let window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -20_000, y: -20_000), size: initial),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.contentView = nil; window.close() }

        // Let SwiftUI lay out, publish preferences (measured heights) and lay out again.
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if size == nil {
                let fitting = host.fittingSize
                if fitting.width > 0, fitting.height > 0, fitting != window.contentLayoutRect.size {
                    window.setContentSize(fitting)
                }
            }
        }
        host.layoutSubtreeIfNeeded()
        host.display()

        let bounds = host.bounds
        guard bounds.width >= 1, bounds.height >= 1,
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                         pixelsWide: Int((bounds.width * scale).rounded()),
                                         pixelsHigh: Int((bounds.height * scale).rounded()),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
            throw Failure(description: "nothing to render (size \(bounds.size))")
        }
        rep.size = bounds.size
        if let appearance {
            appearance.performAsCurrentDrawingAppearance { host.cacheDisplay(in: bounds, to: rep) }
        } else {
            host.cacheDisplay(in: bounds, to: rep)
        }
        guard let png = rep.representation(using: .png, properties: [:]) else {
            throw Failure(description: "PNG encoding failed")
        }
        return png
    }

    /// Writes `data` to `url`, refusing to replace an existing file unless `replace`.
    static func write(_ data: Data, to url: URL, replace: Bool) throws {
        guard url.pathExtension.lowercased() == "png" else { throw Failure(description: "output must be a .png") }
        if FileManager.default.fileExists(atPath: url.path), !replace {
            throw Failure(description: "\(url.path) exists (pass --replace to overwrite it)")
        }
        try data.write(to: url, options: replace ? .atomic : .withoutOverwriting)
    }
}
