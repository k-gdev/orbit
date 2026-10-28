import AppKit
import CoreGraphics
import OrbitCore
import ScreenCaptureKit

/// Small window thumbnails through ScreenCaptureKit (`SCShareableContent` + `SCScreenshotManager`, macOS
/// 14+), kept for a few seconds per window so hovering the same Dock icon again doesn't capture again.
/// Callers check Screen Recording first (`CGPreflightScreenCaptureAccess`), so this never causes a prompt.
@MainActor
final class WindowThumbnailer {
    /// How long a thumbnail is reused.
    static let lifetime: TimeInterval = 3

    private var cache = TimedCache<CGWindowID, CGImage>(lifetime: lifetime, capacity: 48)

    /// Whether thumbnails can be captured now (no prompt: preflight only).
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }

    /// The app's windows as ScreenCaptureKit sees them (on any Space), or none when capture isn't allowed.
    func captureWindows(of pid: pid_t) async -> [SCWindow] {
        guard Self.canCapture else { return [] }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            return content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        } catch {
            Log.info("windows: shareable content unavailable: \(error.localizedDescription)")
            return []
        }
    }

    /// A thumbnail of `window`, at most `DockPreviewLayout.maxThumbnailHeight` points tall at `scale`.
    func thumbnail(of window: SCWindow, scale: CGFloat) async -> CGImage? {
        let now = Date()
        if let cached = cache.value(for: window.windowID, now: now) { return cached }
        guard Self.canCapture else { return nil }
        let pixels = DockPreviewLayout.capturePixelSize(for: window.frame.size, scale: scale)
        let configuration = SCStreamConfiguration()
        configuration.width = pixels.width
        configuration.height = pixels.height
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.ignoreShadowsSingleWindow = true
        let filter = SCContentFilter(desktopIndependentWindow: window)
        do {
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            cache.insert(image, for: window.windowID, now: Date())
            return image
        } catch {
            return nil
        }
    }

    /// Forgets every thumbnail (the preview was turned off).
    func clear() {
        cache.removeAll()
    }
}
