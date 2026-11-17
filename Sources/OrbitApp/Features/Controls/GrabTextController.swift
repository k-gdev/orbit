import AppKit
import OrbitCore

/// Grab Text end to end (spec §8.4): Screen Recording check (asked for on first use, through the shared
/// `PermissionCenter`) → crosshair overlay on every display → ScreenCaptureKit capture of the rectangle →
/// Vision text and barcode recognition off the main thread → the pasteboard → the shared toast HUD
/// ("Copied 3 lines"; a QR code or barcode's payload wins).
@MainActor
final class GrabTextController {
    private let context: SuiteContext
    private let overlay = GrabTextOverlay()
    private var task: Task<Void, Never>?

    init(context: SuiteContext) {
        self.context = context
    }

    /// Starts a grab (the shortcut or the panel button). Ignored while one is in progress.
    func begin() {
        guard !overlay.isShowing, task == nil else { return }
        context.closePanel()
        context.permissions.refresh()
        guard context.permissions.status(.screenRecording) == .granted else {
            context.permissions.request(.screenRecording)
            context.toasts.show(ToastContent(
                message: "Grab Text needs Screen Recording",
                detail: "Allow Orbit in System Settings → Privacy & Security → Screen Recording, then try again. macOS may ask you to reopen Orbit first.",
                isError: true))
            return
        }
        overlay.show { [weak self] selection in
            guard let self, let selection else { return }
            self.task = Task { [weak self] in
                await self?.grab(selection)
                self?.task = nil
            }
        }
    }

    /// Closes the overlay and abandons a grab in progress (the feature stopping).
    func cancel() {
        overlay.cancel()
        task?.cancel()
        task = nil
    }

    private func grab(_ selection: GrabTextSelection) async {
        do {
            let image = try await GrabTextCapture.capture(selection)
            let output = try await Task.detached(priority: .userInitiated) { try TextRecognizer.recognize(image) }.value
            guard !Task.isCancelled else { return }
            let result = GrabTextResult.preferBarcode(payloads: output.payloads, lines: output.lines)
            guard !result.text.isEmpty else {
                context.toasts.show(ToastContent(message: result.hud, detail: "Try a larger area or sharper text."))
                return
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(result.text, forType: .string)
            context.toasts.show(ToastContent(message: result.hud, detail: Self.preview(result.text)))
        } catch {
            Log.error("grab text failed: \(error.localizedDescription)")
            context.toasts.show(ToastContent(message: "Grab Text didn’t work", detail: error.localizedDescription, isError: true))
        }
    }

    /// The first line, shortened, for the toast's detail.
    private static func preview(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return first.count > 80 ? String(first.prefix(79)) + "…" : first
    }
}
