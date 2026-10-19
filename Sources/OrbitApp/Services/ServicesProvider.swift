import AppKit
import OrbitCore

/// Handles the Finder Services / Quick Action "Orbit…" (`NSServices` in Info.plist).
final class ServicesProvider: NSObject {
    private let windowController: WheelWindowController

    init(windowController: WheelWindowController) {
        self.windowController = windowController
        super.init()
    }

    @objc func openWithOrbit(_ pboard: NSPasteboard, userData: String,
                             error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self],
                                       options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        guard !urls.isEmpty else {
            error.pointee = "Orbit did not receive any files." as NSString
            return
        }
        let items = urls.map(DroppedItem.init(url:))
        let point = NSEvent.mouseLocation
        MainActor.assumeIsolated { windowController.show(items: items, at: point) }
    }
}
