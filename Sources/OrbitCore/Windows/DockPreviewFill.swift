import Foundation

/// How the Dock preview shows its strip while ScreenCaptureKit is slow. Its window list (`SCShareableContent`)
/// can take a second or more when nothing has asked for it lately, so the strip waits for it at most
/// `captureWait` from the hover firing, then shows Accessibility's windows as title cards and fills in the
/// thumbnails and the windows on other Spaces when the list arrives. One list is reused for
/// `shareableContentLifetime`, so moving along the Dock doesn't fetch it again for every icon.
public enum DockPreviewFill {
    /// The longest the strip waits for ScreenCaptureKit's window list.
    public static let captureWait: TimeInterval = 0.4
    /// How long one ScreenCaptureKit window list is reused.
    public static let shareableContentLifetime: TimeInterval = 2

    /// What is left of `captureWait` `elapsed` seconds after the hover fired (never negative, never more
    /// than `captureWait`).
    public static func remainingWait(elapsed: TimeInterval) -> TimeInterval {
        min(max(captureWait - elapsed, 0), captureWait)
    }

    /// Whether to show the strip before the capture list is in: only with Accessibility windows to show.
    /// With none (every window on another Space, say) it waits for the list, which may have some.
    public static func showsWithoutCapture(accessibilityEntries: Int) -> Bool {
        accessibilityEntries > 0
    }
}
