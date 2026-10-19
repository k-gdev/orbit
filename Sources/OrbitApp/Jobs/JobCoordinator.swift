import AppKit
import Combine
import OrbitCore

/// Runs jobs for the wheel: routes editor slices, runs `JobRunner`, shows progress and
/// result toasts, and keeps recents. With `outcomeHandler` set it runs headless: no
/// windows, no Finder reveal, no pasteboard writes.
@MainActor
final class JobCoordinator: ObservableObject {
    enum Outcome {
        case finished(JobResult)
        case failed(any Error)
        case cancelled
    }

    let settings: SettingsStore
    let recents = RecentResults()
    private(set) var capabilities: Capabilities
    @Published private(set) var activeJobCount = 0

    /// Set for headless runs; receives each job's outcome instead of any UI.
    var outcomeHandler: ((Outcome) -> Void)?

    private let progressPanels = ProgressPanelController()
    private let toasts = ToastCenter()

    /// Jobs show their progress panel only if still running after this long.
    private static let progressDelay: Duration = .milliseconds(500)

    init(settings: SettingsStore) {
        self.settings = settings
        capabilities = HelperLocator().locate(customFFmpegPath: settings.customFFmpegPath)
    }

    func rescan() {
        capabilities = HelperLocator().locate(customFFmpegPath: settings.customFFmpegPath)
        Log.info("rescanned helpers: ffmpeg=\(capabilities.ffmpeg?.path ?? "none") pages=\(capabilities.pagesBundleID ?? "none") "
            + "keynote=\(capabilities.keynoteBundleID ?? "none") numbers=\(capabilities.numbersBundleID ?? "none")")
    }

    func perform(_ slice: Slice, items: [DroppedItem], near point: CGPoint) {
        guard let action = slice.action else {
            Log.error("slice \(slice.id) has no action")
            report(.failed(OrbitError.unsupported(JobCoordinator.unsupportedMessage)))
            return
        }
        if let editor = slice.editor {
            if outcomeHandler != nil {
                report(.failed(OrbitError.unsupported(EditorRouter.notBuilt)))
            } else {
                EditorRouter.open(editor, items: items, action: action, coordinator: self)
            }
            return
        }
        run(JobRequest(items: items, action: action, options: settings.jobOptions), near: point)
    }

    func run(_ request: JobRequest, near point: CGPoint) {
        let runner = JobRunner(processors: ProcessorRegistry.standard(capabilities: capabilities),
                               capabilities: capabilities)
        let model = ProgressModel()
        let job = RunningJob()
        activeJobCount += 1

        let task = Task { [weak self] in
            let outcome: Outcome
            do {
                let result = try await runner.run(request) { progress in
                    Task { @MainActor in model.progress = progress }
                }
                outcome = .finished(result)
            } catch {
                outcome = (error as? OrbitError) == .cancelled || error is CancellationError ? .cancelled : .failed(error)
            }
            await MainActor.run { self?.finish(outcome, job: job) }
        }
        job.task = task
        model.onCancel = { task.cancel() }

        if outcomeHandler == nil {
            job.delay = Task { [weak self] in
                try? await Task.sleep(for: Self.progressDelay)
                guard let self, !Task.isCancelled, !job.finished else { return }
                job.panel = self.progressPanels.show(model: model, near: point)
            }
        }
    }

    func showError(_ message: String) {
        report(.failed(OrbitError.unsupported(message)))
    }

    // MARK: Completion

    private func finish(_ outcome: Outcome, job: RunningJob) {
        job.finished = true
        job.delay?.cancel()
        if let panel = job.panel { progressPanels.close(panel) }
        activeJobCount -= 1
        report(outcome)
    }

    private func report(_ outcome: Outcome) {
        if let outcomeHandler {
            outcomeHandler(outcome)
            return
        }
        switch outcome {
        case .cancelled:
            Log.info("job cancelled")
        case .failed(let error):
            Log.error("job failed: \(error.localizedDescription)")
            toasts.show(ToastContent(message: error.localizedDescription, isError: true))
        case .finished(let result):
            complete(result)
        }
    }

    private func complete(_ result: JobResult) {
        Haptics.done()
        if settings.revealInFinder, !result.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
        }
        if let text = result.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
        showToast(for: result)
        if !result.outputs.isEmpty || result.clipboardText != nil { recents.add(result) }
    }

    private func showToast(for result: JobResult) {
        let hasOutputs = !result.outputs.isEmpty
        let content = ToastContent(
            message: result.summary,
            detail: result.usedFallbackFolder ? "Saved to Downloads/Orbit" : nil,
            canOpen: hasOutputs, canReveal: hasOutputs, canUndo: result.undo != nil)
        var dismiss: () -> Void = {}
        let actions = ToastActions(
            open: {
                for url in result.outputs { NSWorkspace.shared.open(url) }
                dismiss()
            },
            reveal: {
                NSWorkspace.shared.activateFileViewerSelecting(result.outputs)
            },
            undo: { [weak self] in
                guard let self, let undo = result.undo else { return }
                dismiss()
                do {
                    try UndoPerformer.perform(undo)
                    self.recents.remove(outputs: result.outputs)
                    self.toasts.show(ToastContent(message: "Undone"))
                } catch {
                    Log.error("undo failed: \(error.localizedDescription)")
                    self.toasts.show(ToastContent(message: "Couldn't undo: \(error.localizedDescription)", isError: true))
                }
            })
        dismiss = toasts.show(content, actions: actions)
    }

    /// Reveals a recent result in Finder, or copies its text again when it wrote no files.
    func openRecent(_ entry: RecentResults.Entry) {
        if !entry.result.outputs.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(entry.result.outputs)
        } else if let text = entry.result.clipboardText {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        }
    }

    static let unsupportedMessage = "Orbit can't do that with this file."
}

@MainActor
private final class RunningJob {
    var task: Task<Void, Never>?
    var delay: Task<Void, Never>?
    var panel: HUDPanel?
    var finished = false
}
