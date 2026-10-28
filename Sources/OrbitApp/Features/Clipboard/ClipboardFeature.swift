import AppKit
import Combine
import OrbitCore
import SwiftUI

/// Clipboard history (spec §5.5). While on, it watches the pasteboard (a cheap poll of its change
/// count), keeps the history on disk, shows it in the menu bar tab and opens a popup at the pointer on a
/// global shortcut. Choosing an entry writes it back to the pasteboard and, when Orbit has Accessibility
/// and the setting is on, presses ⌘V in the app you came from; otherwise it just copies and says so.
///
/// Off, it does nothing: no timer, no shortcut, no window. `start()` and `stop()` are idempotent.
@MainActor
final class ClipboardFeature: SuiteFeature {
    static let hotKeyID = "clipboard.popup"

    let id = FeatureID.clipboard
    private let context: SuiteContext
    private let settings: ClipboardSettings
    private let model: ClipboardModel
    private let watcher = PasteboardWatcher()
    private let popup: ClipboardPopupController
    private var shortcutSubscription: AnyCancellable?
    private var isRunning = false
    /// Why the shortcut could not be registered (shown in Settings), or nil.
    private var shortcutProblem: String?

    /// Cheap and side-effect free: loads the settings and makes the (empty, unloaded) model.
    init(context: SuiteContext) {
        self.context = context
        settings = ClipboardSettings(defaults: context.defaults)
        let folder = context.supportDirectory.appending(path: FeatureID.clipboard.title, directoryHint: .isDirectory)
        model = ClipboardModel(settings: settings, store: ClipboardStore(directory: folder))
        popup = ClipboardPopupController(model: model)
        popup.onChoose = { [weak self] item, app in self?.paste(item, into: app) }
        popup.willPaste = { [weak self] in self?.canPasteDirectly() ?? false }
    }

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        model.loadIfNeeded()
        watcher.start(
            policy: { [settings] in
                PasteboardPolicy(ignoredBundleIDs: settings.ignoredBundleIDs, maxItemBytes: settings.limits.maxItemBytes)
            },
            onCapture: { [weak self] capture in self?.model.record(capture) })
        registerHotKey(settings.popupShortcut)
        // Re-register when the shortcut is changed in Settings. `$popupShortcut` fires before the value
        // is stored, so use the value it delivers.
        shortcutSubscription = settings.$popupShortcut
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] combo in self?.registerHotKey(combo) }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        shortcutSubscription = nil
        watcher.stop()
        context.hotKeys.unregister(id: Self.hotKeyID)
        shortcutProblem = nil
        popup.hide(restoreFocus: false)
        model.trimMemory()
    }

    func panelDidAppear() {
        model.enforceLimits()
    }

    // MARK: Views

    func makePanelView() -> AnyView {
        AnyView(ClipboardPanelView(model: model, settings: settings,
                                   actions: ClipboardPanelActions(copy: { [weak self] item in self?.copyFromPanel(item) })))
    }

    func makeSettingsView() -> AnyView {
        AnyView(ClipboardSettingsView(settings: settings, model: model, permissions: context.permissions,
                                      conflict: { [weak self] combo in self?.conflictMessage(for: combo) }))
    }

    /// The list scrolls inside the tab, so the search field stays at the top.
    static var managesOwnScrolling: Bool { true }

    static func snapshotViews() -> FeatureSnapshotViews {
        let settings = ClipboardFixtures.settings(ignoredApps: ["com.apple.keychainaccess", "com.apple.Passwords"])
        let model = ClipboardFixtures.model(settings: settings)
        let permissions = PermissionCenter(live: false, fixed: [.accessibility: .granted])
        return FeatureSnapshotViews(
            panel: ClipboardPanelView(model: model, settings: settings, actions: ClipboardPanelActions()),
            settings: ClipboardSettingsView(settings: settings, model: model, permissions: permissions, conflict: { _ in nil }))
    }

    // MARK: Shortcut

    private func registerHotKey(_ combo: KeyCombo) {
        let registered = context.hotKeys.register(combo, id: Self.hotKeyID) { [weak self] in self?.togglePopup() }
        if registered {
            shortcutProblem = nil
        } else if let owner = context.hotKeys.owner(of: combo), owner != Self.hotKeyID {
            shortcutProblem = "Already used by \(Self.title(ofHotKey: owner))"
        } else {
            shortcutProblem = "macOS refused this shortcut"
        }
    }

    /// A message for the shortcut recorder when `combo` clashes with another Orbit shortcut, else the
    /// reason the current shortcut failed to register.
    private func conflictMessage(for combo: KeyCombo) -> String? {
        if let owner = context.hotKeys.owner(of: combo), owner != Self.hotKeyID {
            return "Already used by \(Self.title(ofHotKey: owner))"
        }
        return combo == settings.popupShortcut ? shortcutProblem : nil
    }

    private static func title(ofHotKey id: String) -> String {
        if id == "micMute" { return "Mic mute" }
        let prefix = id.split(separator: ".").first.map(String.init) ?? id
        return FeatureID(rawValue: prefix)?.title ?? id
    }

    private func togglePopup() {
        if popup.isVisible {
            popup.hide(restoreFocus: true)
        } else {
            popup.show(at: NSEvent.mouseLocation)
        }
    }

    // MARK: Choosing an entry

    /// Whether choosing an entry would press ⌘V: the setting is on and Orbit is trusted for Accessibility
    /// right now (read fresh each time; it may have been granted or revoked since `start()`).
    private func canPasteDirectly() -> Bool {
        guard settings.pasteDirectly else { return false }
        context.permissions.refresh()
        return context.permissions.status(.accessibility) == .granted && PasteInjector.isTrusted
    }

    /// The popup's choice: write it to the pasteboard, then paste or just say it was copied.
    private func paste(_ item: ClipboardItem, into app: NSRunningApplication?) {
        guard writeToPasteboard(item) else { return }
        guard canPasteDirectly() else {
            showCopiedHint(settings.pasteDirectly ? "Press ⌘V to paste. Orbit needs Accessibility to do it for you." : "Press ⌘V to paste.")
            return
        }
        Task { @MainActor in
            await PasteInjector.bringToFront(app)
            // Give the app a beat to take focus back before the key press arrives.
            try? await Task.sleep(for: .milliseconds(60))
            if !PasteInjector.postPaste() { showCopiedHint("Press ⌘V to paste.") }
        }
    }

    /// A click in the menu bar tab: copy only (the panel closes; the user pastes where they like).
    private func copyFromPanel(_ item: ClipboardItem) {
        guard writeToPasteboard(item) else { return }
        context.closePanel()
        showCopiedHint(nil)
    }

    /// Puts the entry on the general pasteboard, tells the watcher it was Orbit's own write, and moves
    /// the entry to the top. False (with a toast) when its content is gone.
    private func writeToPasteboard(_ item: ClipboardItem) -> Bool {
        guard let payload = model.payload(for: item) else {
            model.remove(item.id)
            context.toasts.show(ToastContent(message: "That copy is no longer available", isError: true))
            return false
        }
        switch PasteboardWriter.write(item, payload: payload, to: .general) {
        case .written(let changeCount):
            watcher.ignoreChange(at: changeCount)
            model.markUsed(item.id)
            return true
        case .unavailable(let reason):
            context.toasts.show(ToastContent(message: reason, isError: true))
            return false
        }
    }

    private func showCopiedHint(_ detail: String?) {
        let dismiss = context.toasts.show(ToastContent(message: "Copied", detail: detail))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(detail == nil ? 1.4 : 2.8))
            dismiss()
        }
    }
}
