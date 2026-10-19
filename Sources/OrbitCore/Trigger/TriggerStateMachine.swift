import Foundation

public struct InputSample: Sendable {
    public var time: TimeInterval
    public var buttonDown: Bool
    public var modifiers: ModifierSet
    public var location: CGPoint
    public var dragChangeCount: Int
    public var dragHasFiles: Bool

    public init(time: TimeInterval, buttonDown: Bool, modifiers: ModifierSet, location: CGPoint,
                dragChangeCount: Int, dragHasFiles: Bool) {
        self.time = time; self.buttonDown = buttonDown; self.modifiers = modifiers
        self.location = location; self.dragChangeCount = dragChangeCount; self.dragHasFiles = dragHasFiles
    }
}

public enum TriggerEvent: Equatable, Sendable {
    case open(WheelKind, at: CGPoint)
    case switchTo(WheelKind)
    case close
}

/// Decides when the wheel opens, switches and closes from a stream of input samples.
public struct TriggerStateMachine: Sendable {
    public var bindings: TriggerBindings
    public var isEnabled = true
    private let settleDelay: TimeInterval

    private var wasDown = false
    private var baselineMods: ModifierSet = []
    private var baselineCount = 0
    private var openKind: WheelKind?
    private var blocked = false
    private var candidate: (kind: WheelKind, since: TimeInterval)?

    public init(bindings: TriggerBindings, settleDelay: TimeInterval = 0.05) {
        self.bindings = bindings
        self.settleDelay = settleDelay
    }

    public mutating func feed(_ s: InputSample) -> TriggerEvent? {
        guard s.buttonDown else {
            let wasOpen = openKind != nil
            wasDown = false
            openKind = nil
            blocked = false
            candidate = nil
            return wasOpen ? .close : nil
        }
        if !wasDown {
            wasDown = true
            baselineMods = s.modifiers
            baselineCount = s.dragChangeCount
            candidate = nil
        }
        baselineMods.formIntersection(s.modifiers)

        guard s.dragChangeCount != baselineCount, s.dragHasFiles else { candidate = nil; return nil }
        guard let kind = bindings.wheel(for: s.modifiers.subtracting(baselineMods)) else {
            candidate = nil
            return nil
        }
        if kind == openKind { candidate = nil; return nil }
        if candidate?.kind != kind { candidate = (kind, s.time) }
        guard let c = candidate, s.time - c.since >= settleDelay else { return nil }

        if openKind != nil {
            openKind = kind
            candidate = nil
            return .switchTo(kind)
        }
        guard isEnabled, !blocked else { return nil }
        openKind = kind
        candidate = nil
        return .open(kind, at: s.location)
    }

    /// The overlay was dismissed by something other than button-up (e.g. a slice was applied).
    public mutating func overlayDidClose() {
        openKind = nil
        candidate = nil
        blocked = true
    }
}
