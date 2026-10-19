import AppKit
import OrbitCore

/// Opens the editor a slice asks for. Only Choose… exists so far; Tasks 26-28 replace the rest.
@MainActor
enum EditorRouter {
    static let notBuilt = "This editor isn't built yet."

    static func open(_ kind: EditorKind, items: [DroppedItem], action: SliceAction, coordinator: JobCoordinator) {
        switch kind {
        case .chooseFolder:
            guard case .action(let id, _) = action else {
                coordinator.showError(notBuilt)
                return
            }
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            NSApp.activate()
            guard panel.runModal() == .OK, let folder = panel.url else { return }
            let request = JobRequest(items: items, action: .action(id, .folder(folder)),
                                     options: coordinator.settings.jobOptions)
            coordinator.run(request, near: NSEvent.mouseLocation)
        default:
            coordinator.showError(notBuilt)
        }
    }
}
