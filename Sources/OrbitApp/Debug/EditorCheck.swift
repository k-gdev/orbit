import AppKit
import OrbitCore
import SwiftUI

/// Hidden command-line mode: opens the real editor panels offscreen-ish (an accessory app, no Dock icon) and checks what the
/// ImageRenderer snapshots cannot see, because they bypass `EditorWindowController.present`:
///
///     Orbit --check-editors <image file>
///
/// - every panel opens with a non-empty frame, visible, on a screen (the zero-height-panel defect);
/// - closing a panel releases its controller (the Markup retain-cycle defect), including a Markup opened through `EditorRouter`;
/// - a failing preview render publishes an error and a later success clears it (Adjust and Add BG).
///
/// Prints one line per check and exits 0 when all pass, 1 otherwise. Needs a logged-in GUI session.
enum EditorCheck {
    static let flag = "--check-editors"

    @MainActor
    static func runIfRequested(_ arguments: [String]) {
        guard let start = arguments.firstIndex(of: flag) else { return }
        guard arguments.indices.contains(start + 1) else {
            FileHandle.standardError.write(Data("usage: Orbit --check-editors <image file>\n".utf8))
            exit(64)
        }
        let url = URL(fileURLWithPath: arguments[start + 1])
        NSApplication.shared.setActivationPolicy(.accessory)
        let checker = Checker()
        run(url, check: checker)
        print(checker.failures == 0 ? "all editor checks passed" : "\(checker.failures) editor check(s) failed")
        exit(checker.failures == 0 ? 0 : 1)
    }

    final class Checker {
        private(set) var failures = 0

        func callAsFunction(_ name: String, _ ok: Bool, _ detail: String = "") {
            print("\(ok ? "PASS" : "FAIL")  \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
            if !ok { failures += 1 }
        }
    }

    @MainActor
    private static func spin(until condition: () -> Bool, timeout: TimeInterval = 15) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    @MainActor
    private static func settle() { spin(until: { false }, timeout: 0.3) }

    @MainActor
    private static func run(_ url: URL, check: Checker) {
        let item = DroppedItem(url: url)

        // Markup, through the router (the path the app takes).
        var markupSubmissions = 0
        weak var markup: EditorWindowController?
        autoreleasepool {
            let controller = EditorRouter.openMarkup([item], index: 0, action: .tool(.markup, nil), options: { JobOptions() },
                                                     submit: { _ in markupSubmissions += 1 }, center: nil)
            markup = controller
            settle()
            checkPanel("markup", controller, check)
            controller.close()
        }
        settle()
        check("markup controller released after close (no retain cycle)", markup == nil)

        // Adjust and Add BG, presented as the router presents them.
        weak var adjust: EditorWindowController?
        let adjustModel = AdjustModel()
        autoreleasepool {
            let controller = EditorWindowController.present(width: ImageAdjustEditor.width, content: { close, _ in
                ImageAdjustEditor(title: "Adjust Photo", model: adjustModel, onClose: close, onApply: { _ in })
            })
            adjust = controller
            settle()
            checkPanel("adjust", controller, check)
            controller.close()
        }
        settle()
        check("adjust controller released after close", adjust == nil)

        weak var background: EditorWindowController?
        let backgroundModel = BackgroundModel()
        autoreleasepool {
            let controller = EditorWindowController.present(width: AddBackgroundEditor.width, content: { close, _ in
                AddBackgroundEditor(title: "Add Background", model: backgroundModel, onClose: close, onApply: { _ in })
            })
            background = controller
            settle()
            checkPanel("addbg", controller, check)
            controller.close()
        }
        settle()
        check("addbg controller released after close", background == nil)

        // Preview failures are published, not swallowed.
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let adjustProbe = AdjustModel()
        adjustProbe.renderer = { _, _ in throw Boom() }
        if let image = try? EditorImage.load(url) {
            adjustProbe.image = image
            adjustProbe.scheduleRender()
            spin(until: { adjustProbe.previewError != nil })
            check("adjust: a failing render publishes previewError", adjustProbe.previewError?.contains("boom") == true,
                  adjustProbe.previewError ?? "nil")
            adjustProbe.renderer = { try AdjustRenderer.render($0, $1) }
            adjustProbe.scheduleRender()
            spin(until: { adjustProbe.previewError == nil && adjustProbe.preview != nil })
            check("adjust: a later success clears previewError and sets the preview",
                  adjustProbe.previewError == nil && adjustProbe.preview != nil)

            let backgroundProbe = BackgroundModel()
            backgroundProbe.composer = { _, _, _ in throw Boom() }
            backgroundProbe.set(image: image, subject: image.proxy)
            backgroundProbe.scheduleRender()
            spin(until: { backgroundProbe.previewError != nil })
            check("addbg: a failing render publishes previewError", backgroundProbe.previewError?.contains("boom") == true,
                  backgroundProbe.previewError ?? "nil")
            backgroundProbe.composer = { try BackgroundComposer.compose(subject: $0, original: $1, style: $2) }
            backgroundProbe.scheduleRender()
            spin(until: { backgroundProbe.previewError == nil && backgroundProbe.preview != nil })
            check("addbg: a later success clears previewError and sets the preview",
                  backgroundProbe.previewError == nil && backgroundProbe.preview != nil)
        } else {
            check("load \(url.lastPathComponent) for the preview checks", false)
        }
    }

    @MainActor
    private static func checkPanel(_ name: String, _ controller: EditorWindowController,
                                   _ check: Checker) {
        let frame = controller.frame
        check("\(name): panel frame is non-empty", frame.width >= 1 && frame.height >= EditorGeometry.minimumPanelHeight, "\(frame)")
        check("\(name): panel is visible", controller.isVisible)
        let onScreen = NSScreen.screens.contains { $0.frame.intersects(frame) }
        check("\(name): panel is on a screen", onScreen || NSScreen.screens.isEmpty, "\(frame)")
    }
}
