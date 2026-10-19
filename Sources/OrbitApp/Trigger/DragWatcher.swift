import AppKit
import Combine
import OrbitCore

/// Turns input samples into wheel actions: feeds `TriggerStateMachine` and opens,
/// switches and hides the wheel. Keeps the machine in step with the Enabled setting
/// and the trigger bindings.
@MainActor
final class DragWatcher {
    /// Logs every sample and trigger event to orbit.log (`--diagnose-trigger`).
    var logsSamples = false

    /// How long the wheel stays up after the button is released, so the drop lands first.
    static let hideDelay: Duration = .milliseconds(150)

    private let sampler: InputSampler
    private let wheel: WheelController
    private var stateMachine: TriggerStateMachine
    private var cancellables: Set<AnyCancellable> = []
    private var hideTask: Task<Void, Never>?
    /// The button state of the last sample the state machine saw.
    private var lastButtonDown = false

    init(sampler: InputSampler, wheel: WheelController, settings: SettingsStore) {
        self.sampler = sampler
        self.wheel = wheel
        stateMachine = TriggerStateMachine(bindings: settings.bindings)
        stateMachine.isEnabled = settings.isEnabled

        settings.$isEnabled
            .sink { [weak self] enabled in self?.stateMachine.isEnabled = enabled }
            .store(in: &cancellables)
        settings.$bindings
            .sink { [weak self] bindings in self?.stateMachine.bindings = bindings }
            .store(in: &cancellables)

        sampler.keepsSampling = { [weak wheel] in wheel?.isVisible ?? false }
        wheel.onCancel = { [weak self] in self?.overlayDidClose() }
    }

    func start() {
        sampler.start { [weak self] sample in self?.handle(sample) }
    }

    /// Feeds one sample to the state machine and acts on the event it yields.
    func handle(_ sample: InputSample) {
        lastButtonDown = sample.buttonDown
        let event = stateMachine.feed(sample)
        if logsSamples { Log.info(Self.describe(sample, event)) }
        guard let event else { return }

        switch event {
        case .open(let kind, let point):
            let urls = NSPasteboard(name: .drag).droppedFileURLs
            guard !urls.isEmpty else {
                Log.error("trigger: drag pasteboard has no readable file URLs")
                stateMachine.overlayDidClose()
                return
            }
            hideTask?.cancel()
            hideTask = nil
            wheel.show(kind: kind, items: urls.map(DroppedItem.init(url:)), at: point)
        case .switchTo(let kind):
            wheel.switchTo(kind)
        case .close:
            scheduleHide()
        }
    }

    /// The drag ended without a drop on a slice (Esc, or a drop on the hub). While the
    /// button is still held the machine must not treat the wheel as open; once it's up
    /// the machine has already reset.
    private func overlayDidClose() {
        guard lastButtonDown else { return }
        stateMachine.overlayDidClose()
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hideDelay)
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.wheel.hide()
        }
    }

    // MARK: Diagnostics

    private static func describe(_ s: InputSample, _ event: TriggerEvent?) -> String {
        var line = "trigger sample t=\(String(format: "%.3f", s.time)) buttonDown=\(s.buttonDown) "
            + "modifiers=\(describe(s.modifiers)) location=(\(Int(s.location.x.rounded())), \(Int(s.location.y.rounded()))) "
            + "changeCount=\(s.dragChangeCount) dragHasFiles=\(s.dragHasFiles)"
        if let event { line += " -> \(describe(event))" }
        return line
    }

    private static func describe(_ mods: ModifierSet) -> String {
        let names: [(ModifierSet, String)] = [(.shift, "shift"), (.control, "control"), (.option, "option"), (.command, "command")]
        return "[" + names.filter { mods.contains($0.0) }.map(\.1).joined(separator: ",") + "]"
    }

    private static func describe(_ event: TriggerEvent) -> String {
        switch event {
        case .open(let kind, let p): "open \(kind.rawValue) at (\(Int(p.x.rounded())), \(Int(p.y.rounded())))"
        case .switchTo(let kind): "switch to \(kind.rawValue)"
        case .close: "close"
        }
    }
}
