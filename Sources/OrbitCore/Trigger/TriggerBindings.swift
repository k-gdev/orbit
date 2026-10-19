public struct TriggerBindings: Codable, Equatable, Sendable {
    public var convert: [ModifierSet]
    public var tools: [ModifierSet]
    public var actions: [ModifierSet]

    public init(convert: [ModifierSet], tools: [ModifierSet], actions: [ModifierSet]) {
        self.convert = convert; self.tools = tools; self.actions = actions
    }

    public static let defaults = TriggerBindings(
        convert: [[.shift], [.command]],
        tools: [[.shift, .option], [.option, .command]],
        actions: [[.control]])

    /// Exact match only: `[.shift, .command]` does not match a `[.shift]` binding.
    public func wheel(for mods: ModifierSet) -> WheelKind? {
        guard !mods.isEmpty else { return nil }
        if convert.contains(mods) { return .convert }
        if tools.contains(mods) { return .tools }
        if actions.contains(mods) { return .actions }
        return nil
    }
}
