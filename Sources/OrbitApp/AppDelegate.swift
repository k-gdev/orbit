import AppKit
import OrbitCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnoseTrigger: Bool
    private var settings: SettingsStore?
    private var coordinator: JobCoordinator?
    private var wheel: WheelController?
    private var dragWatcher: DragWatcher?
    private var statusItemController: StatusItemController?
    private var settingsWindow: SettingsWindowController?
    private var windowController: WheelWindowController?
    private var servicesProvider: ServicesProvider?

    /// `diagnoseTrigger` logs every trigger input sample and drop callback to orbit.log.
    init(diagnoseTrigger: Bool) {
        self.diagnoseTrigger = diagnoseTrigger
        super.init()
    }

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
        let dragWatcher = DragWatcher(sampler: InputSampler(), wheel: wheel, settings: settings)
        if diagnoseTrigger {
            Log.info("trigger diagnostics on: logging every input sample")
            dragWatcher.logsSamples = true
            wheel.logsDropEvents = true
        }
        dragWatcher.start()
        self.settings = settings
        self.coordinator = coordinator
        self.wheel = wheel
        self.dragWatcher = dragWatcher
        let settingsWindow = SettingsWindowController(settings: settings, coordinator: coordinator)
        self.settingsWindow = settingsWindow
        let windowController = WheelWindowController(wheel: wheel)
        self.windowController = windowController
        let provider = ServicesProvider(windowController: windowController)
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
        statusItemController = StatusItemController(settings: settings, coordinator: coordinator, wheel: wheel,
                                                    windowController: windowController,
                                                    showSettings: { settingsWindow.show() })
    }
}
