import AppKit
import OrbitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings: SettingsStore?
    private var coordinator: JobCoordinator?
    private var wheel: WheelController?
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Orbit launched")
        let settings = SettingsStore()
        Haptics.settings = settings
        let coordinator = JobCoordinator(settings: settings)
        let wheel = WheelController(settings: settings)
        wheel.capabilities = { [weak coordinator] in coordinator?.capabilities ?? Capabilities() }
        wheel.onSelect = { [weak coordinator] slice, items in
            coordinator?.perform(slice, items: items, near: NSEvent.mouseLocation)
        }
        self.settings = settings
        self.coordinator = coordinator
        self.wheel = wheel
        statusItemController = StatusItemController(settings: settings, coordinator: coordinator, wheel: wheel)
    }
}
