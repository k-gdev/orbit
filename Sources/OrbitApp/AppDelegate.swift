import AppKit
import OrbitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Orbit launched")
        statusItemController = StatusItemController()
    }
}
