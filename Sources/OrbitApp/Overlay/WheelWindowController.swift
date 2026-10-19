import AppKit
import OrbitCore

/// The keyboard path (spec §6.1): the wheel as a key window for the Finder Quick Action and
/// "Open Files…". Mouse hover and click come from `WheelController`'s interactive mode; this
/// adds arrows, Return, Esc and ⌘/⌥/⌃ to switch wheels.
@MainActor
final class WheelWindowController {
    private let wheel: WheelController
    private var model: WheelModel { wheel.model }

    init(wheel: WheelController) {
        self.wheel = wheel
    }

    func show(items: [DroppedItem], at screenPoint: CGPoint) {
        wheel.interactiveKeyHandler = { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) ?? false }
        }
        wheel.showDebug(kind: .convert, items: items, at: screenPoint)
    }

    // MARK: Events

    /// Returns true when the event was consumed.
    func handle(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            if let kind = Self.wheelKind(for: event.modifierFlags) { wheel.switchTo(kind) }
            return false
        }
        guard let key = Self.navKey(forKeyCode: event.keyCode) else { return false }
        return handle(key)
    }

    static func navKey(forKeyCode code: UInt16) -> NavKey? {
        switch code {
        case 123: return .left
        case 124: return .right
        case 125: return .down
        case 126: return .up
        case 36, 76: return .enter
        case 53: return .escape
        default: return nil
        }
    }

    /// ⌘ Convert, ⌥ Tools, ⌃ Actions: only when exactly one of the three is down.
    static func wheelKind(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        let relevant = flags.intersection([.command, .option, .control])
        switch relevant {
        case .command: return .convert
        case .option: return .tools
        case .control: return .actions
        default: return nil
        }
    }

    func handle(_ key: NavKey) -> Bool {
        let slices = model.content.slices
        if let parent = model.openSubRing, slices.indices.contains(parent) {
            return handleSubRing(key, children: slices[parent].children)
        }
        var nav = navigator(count: slices.count, at: model.highlighted)
        switch nav.handle(key) {
        case .moved(let index):
            model.setHighlight(index)
        case .apply(let index):
            let slice = slices[index]
            if slice.children.isEmpty { wheel.apply(slice) } else { model.openSubRing(at: index) }
        case .close:
            wheel.hide()
            wheel.onCancel?()
        case .none:
            break
        }
        return true
    }

    private func handleSubRing(_ key: NavKey, children: [Slice]) -> Bool {
        var nav = navigator(count: children.count, at: model.subHighlighted)
        switch nav.handle(key) {
        case .moved(let index):
            model.setSubHighlight(index)
        case .apply(let index):
            wheel.apply(children[index])
        case .close:
            model.closeSubRing()
        case .none:
            break
        }
        return true
    }

    /// A navigator already standing on `index`, so hover and keyboard stay in step.
    private func navigator(count: Int, at index: Int?) -> WheelKeyboardNavigator {
        var nav = WheelKeyboardNavigator(count: count)
        if let index { for _ in 0...index { _ = nav.handle(.right) } }
        return nav
    }
}
