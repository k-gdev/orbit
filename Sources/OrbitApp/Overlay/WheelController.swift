import AppKit
import OrbitCore
import SwiftUI

/// Owns the overlay panel and the wheel model: shows the wheel for a set of
/// dropped items, switches between wheels and hides it again. While shown, the
/// panel is the drop target for the drag (`DropTargetView`).
@MainActor
final class WheelController {
    let model: WheelModel
    var onSelect: ((Slice, [DroppedItem]) -> Void)?
    /// The drag ended over the wheel without a drop on a slice (Esc, or the hub).
    var onCancel: (() -> Void)?
    /// Logs drag-destination callbacks to orbit.log (`--diagnose-trigger`).
    var logsDropEvents = false
    /// Helper availability used to build slices. Task 10 points this at the job coordinator.
    var capabilities: () -> Capabilities

    /// Wheel centre in screen coordinates while shown.
    private(set) var center: CGPoint = .zero
    var isVisible: Bool { panel.isVisible }

    private let settings: SettingsStore
    private let panel = OverlayPanel()
    private let dropTarget: DropTargetView
    private var thumbnailTask: Task<Void, Never>?
    private var debugMonitors: [Any] = []

    private var geometry: WheelGeometry { model.geometry }
    /// Keeps the petal disc, with room for the highlight's scale, fully on screen.
    private var placementRadius: Double { geometry.outerRadius + 20 }

    init(settings: SettingsStore, geometry: WheelGeometry = .standard) {
        self.settings = settings
        model = WheelModel(geometry: geometry)
        capabilities = { HelperLocator().locate(customFFmpegPath: settings.customFFmpegPath) }
        let bounds = NSRect(x: 0, y: 0, width: geometry.panelSide, height: geometry.panelSide)
        let host = NSHostingView(rootView: WheelView(model: model))
        host.frame = bounds
        host.autoresizingMask = [.width, .height]
        dropTarget = DropTargetView(frame: bounds)
        dropTarget.addSubview(host)
        panel.contentView = dropTarget
        dropTarget.wheel = self
    }

    func show(kind: WheelKind, items: [DroppedItem], at screenPoint: CGPoint) {
        let wasVisible = panel.isVisible
        model.load(kind: kind, content: content(for: kind, items: items), items: items)
        loadThumbnail(for: items)

        let screen = NSScreen.screens.first { NSMouseInRect(screenPoint, $0.frame, false) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? CGRect(origin: screenPoint, size: .zero)
        center = WheelPlacement.center(for: screenPoint, radius: placementRadius, in: visible)
        let side = geometry.panelSide
        panel.setFrame(NSRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side), display: false)
        // Take drag-destination events from the moment it appears, so the drop can land
        // on it; `hide()` restores click-through. The panel still never becomes key.
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()

        if !wasVisible {
            // Commit the hidden state (scale 0.85, transparent) before springing in.
            model.revealed = false
            panel.contentView?.layoutSubtreeIfNeeded()
            withAnimation(.spring(duration: 0.25, bounce: 0.3)) { model.revealed = true }
        }
    }

    func switchTo(_ kind: WheelKind) {
        guard panel.isVisible else { return }
        let items = model.items
        model.load(kind: kind, content: content(for: kind, items: items), items: items)
        model.updatePointer(offset: offset(of: NSEvent.mouseLocation))
    }

    func hide() {
        stopDebugInput()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        panel.orderOut(nil)
        panel.isInteractive = false // also ignores mouse events again
        model.revealed = false
        model.resetPointer()
    }

    /// How far from the centre the panel takes the drop: the wheel plus its hit margin,
    /// or out to the sub-ring's margin while one is open. Nothing is selectable past it.
    var activeRadius: Double {
        model.openSubRing == nil ? geometry.outerRadius + geometry.hitMargin
                                 : geometry.subRingOuter + geometry.hitMargin
    }

    /// Called with each input sample while shown for a drag (ruling R25). Past
    /// `activeRadius` the panel lets the drag through, so a drop there reaches whatever is
    /// beneath as if Orbit weren't there (spec §4); inside it the panel is the drop target.
    func updateDropRegion(pointer screenPoint: CGPoint) {
        guard panel.isVisible, !panel.isInteractive else { return }
        let pointer = offset(of: screenPoint)
        let outside = hypot(pointer.dx, pointer.dy) > activeRadius
        guard outside != panel.ignoresMouseEvents else { return }
        panel.ignoresMouseEvents = outside
        if logsDropEvents {
            Log.info("drop: panel \(outside ? "lets drags through" : "takes drops") at r=\(Int(hypot(pointer.dx, pointer.dy)))")
        }
        // The drag now goes elsewhere: clear the highlight as draggingExited would.
        if outside { model.resetPointer() }
    }

    /// Pointer offset from the wheel centre, `dy` up (screen coordinates are y-up).
    func offset(of screenPoint: CGPoint) -> CGVector {
        CGVector(dx: screenPoint.x - center.x, dy: screenPoint.y - center.y)
    }

    private func content(for kind: WheelKind, items: [DroppedItem]) -> WheelContent {
        SliceCatalog.content(for: items, wheel: kind, capabilities: capabilities(),
                             settings: settings.catalogSettings)
    }

    private func loadThumbnail(for items: [DroppedItem]) {
        thumbnailTask?.cancel()
        model.thumbnail = nil
        guard let url = items.first?.url else { return }
        let side = geometry.deadZoneRadius * 2
        thumbnailTask = Task { [weak self] in
            let image = await Thumbnails.image(for: url, size: CGSize(width: side, height: side))
            guard let self, !Task.isCancelled, self.model.items.first?.url == url else { return }
            self.model.thumbnail = image
        }
    }

    // MARK: Debug preview (menu bar → Debug → Show Wheel for File…)

    /// Shows the wheel as an interactive window: the mouse drives the highlight,
    /// a click selects, Tab cycles the wheels and Esc hides.
    func showDebug(kind: WheelKind, items: [DroppedItem], at screenPoint: CGPoint) {
        panel.isInteractive = true
        show(kind: kind, items: items, at: screenPoint)
        panel.makeKey()
        startDebugInput()
        model.updatePointer(offset: offset(of: NSEvent.mouseLocation))
    }

    private func startDebugInput() {
        stopDebugInput()
        let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged, .leftMouseDown, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleDebug(event) ?? true } ? event : nil
        }
        // Clicks and moves outside Orbit's own windows (mouse events need no permission).
        let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { _ = self?.handleDebug(event) }
        }
        debugMonitors = [local, global].compactMap { $0 }
    }

    private func stopDebugInput() {
        debugMonitors.forEach(NSEvent.removeMonitor)
        debugMonitors = []
    }

    /// Returns whether the event should continue to its normal destination.
    private func handleDebug(_ event: NSEvent) -> Bool {
        switch event.type {
        case .mouseMoved, .leftMouseDragged:
            model.updatePointer(offset: offset(of: NSEvent.mouseLocation))
            return true
        case .leftMouseDown:
            model.updatePointer(offset: offset(of: NSEvent.mouseLocation))
            if let slice = model.selectedSlice {
                let items = model.items
                hide()
                onSelect?(slice, items)
                return false
            }
            if model.highlighted != nil { return false } // a parent slice: wait for its sub-ring
            // The hub or outside the wheel cancels; a click elsewhere still reaches its target.
            let onWheel = event.window === panel
            hide()
            return !onWheel
        case .keyDown:
            switch event.keyCode {
            case 48: // Tab
                let kinds = WheelKind.allCases
                let step = event.modifierFlags.contains(.shift) ? kinds.count - 1 : 1
                let current = kinds.firstIndex(of: model.kind) ?? 0
                switchTo(kinds[(current + step) % kinds.count])
                return false
            case 53: // Esc
                hide()
                return false
            default:
                return true
            }
        default:
            return true
        }
    }
}
