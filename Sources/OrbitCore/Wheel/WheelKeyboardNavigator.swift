public enum NavKey: Sendable { case left, right, up, down, enter, escape }

public enum NavOutcome: Equatable, Sendable { case moved(Int), apply(Int), close, none }

public struct WheelKeyboardNavigator: Sendable {
    private let count: Int
    public private(set) var highlighted: Int?

    public init(count: Int) { self.count = count }

    public mutating func handle(_ key: NavKey) -> NavOutcome {
        switch key {
        case .escape: return .close
        case .enter:
            guard let h = highlighted else { return .none }
            return .apply(h)
        case .right, .down: return move(+1)
        case .left, .up: return move(-1)
        }
    }

    private mutating func move(_ step: Int) -> NavOutcome {
        guard count > 0 else { return .none }
        let next = highlighted.map { ($0 + step + count) % count } ?? 0
        highlighted = next
        return .moved(next)
    }
}
