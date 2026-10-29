import AppKit
import OrbitCore
import ScreenCaptureKit

/// Captures the selected rectangle with ScreenCaptureKit's one-shot screenshot API (macOS 14+, Orbit's
/// minimum), at the display's full pixel density and without the cursor. Orbit's own windows are left
/// out, so the overlay never shows in the capture. Needs Screen Recording.
enum GrabTextCapture {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func capture(_ selection: GrabTextSelection) async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == selection.displayID }) else {
            throw Failure(message: "That display is no longer connected.")
        }
        let me = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == me }
        let filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = selection.rect
        configuration.width = max(1, Int((selection.rect.width * scale).rounded()))
        configuration.height = max(1, Int((selection.rect.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}
