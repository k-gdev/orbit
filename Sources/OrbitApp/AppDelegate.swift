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
    private var welcomeWindow: WelcomeWindowController?
    private var windowController: WheelWindowController?
    private var servicesProvider: ServicesProvider?
    private var registry: FeatureRegistry?

    /// `diagnoseTrigger` logs every trigger input sample and drop callback to orbit.log.
    init(diagnoseTrigger: Bool) {
        self.diagnoseTrigger = diagnoseTrigger
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("Orbit launched")
        let settings = SettingsStore()
        Haptics.settings = settings
        OrbitTheme.shared.bind(to: settings)
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
        let welcomeWindow = WelcomeWindowController(settings: settings)
        self.welcomeWindow = welcomeWindow
        let settingsWindow = SettingsWindowController(settings: settings, coordinator: coordinator,
                                                      showWelcome: { welcomeWindow.show() })
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
        startSuite(settings: settings, coordinator: coordinator)
        // Offer Full Disk Access once, on the first launch where it isn't already granted.
        if welcomeWindow.shouldShowOnLaunch { welcomeWindow.show() }
    }

    /// Builds the suite's shared context and feature registry and starts the features that are on.
    @MainActor
    private func startSuite(settings: SettingsStore, coordinator: JobCoordinator) {
        let hotKeys = HotKeyCenter()
        let context = SuiteContext(settings: settings, suite: SuiteSettings(), defaults: .standard, hotKeys: hotKeys,
                                   permissions: PermissionCenter(),
                                   micMute: MicMuteService(hotKeys: hotKeys, settings: MicMuteSettings()),
                                   toasts: coordinator.toasts, supportDirectory: SuiteContext.defaultSupportDirectory)
        let registry = FeatureRegistry.standard(context: context)
        self.registry = registry
        registry.startEnabled()
    }

    /// Every feature releases what it holds (audio taps, power assertions, hot keys, windows) and the mic
    /// is restored before Orbit exits.
    func applicationWillTerminate(_ notification: Notification) {
        registry?.stopAll()
        Log.info("Orbit quit")
    }
}
