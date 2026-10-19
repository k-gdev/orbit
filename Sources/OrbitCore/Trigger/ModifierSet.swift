public struct ModifierSet: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let shift = ModifierSet(rawValue: 1)
    public static let control = ModifierSet(rawValue: 2)
    public static let option = ModifierSet(rawValue: 4)
    public static let command = ModifierSet(rawValue: 8)
}
