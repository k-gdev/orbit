import Foundation

/// How much history to keep and how large one copy may be. Built from `ClipboardSettings`.
public struct ClipboardLimits: Equatable, Sendable {
    /// One megabyte as Finder counts it (decimal).
    public static let megabyte = 1_000_000

    public var maxItems: Int
    /// Entries older than this are dropped (pinned ones excepted).
    public var maxAge: TimeInterval
    /// The most bytes all stored content may add up to.
    public var maxTotalBytes: Int
    /// A single copy bigger than this is not recorded at all.
    public var maxItemBytes: Int

    public init(maxItems: Int, maxAge: TimeInterval, maxTotalBytes: Int, maxItemBytes: Int) {
        self.maxItems = maxItems
        self.maxAge = maxAge
        self.maxTotalBytes = maxTotalBytes
        self.maxItemBytes = maxItemBytes
    }

    /// The limits in the units the settings use. Values that would make no sense (zero or negative) are
    /// raised to the smallest useful one, so a bad setting can never empty the history. One copy is
    /// never allowed to exceed the whole history's budget.
    public init(maxItems: Int, maxAgeDays: Int, maxMegabytes: Int, maxItemMegabytes: Int) {
        let total = max(maxMegabytes, 1) * Self.megabyte
        self.init(maxItems: max(maxItems, 1),
                  maxAge: TimeInterval(max(maxAgeDays, 1)) * 86_400,
                  maxTotalBytes: total,
                  maxItemBytes: min(max(maxItemMegabytes, 1) * Self.megabyte, total))
    }

    /// Whether a copy of `byteSize` bytes may be recorded.
    public func allowsItem(ofSize byteSize: Int) -> Bool {
        byteSize <= maxItemBytes
    }
}

extension ClipboardHistory {
    /// Applies the limits and returns the evicted entries (so their blobs can be deleted), oldest
    /// first. Pinned entries are exempt from every limit: they are never evicted and they do not count
    /// toward the count or size budgets (otherwise enough pins would leave no room, and every new copy
    /// would be stored and evicted at once). The budgets apply to the unpinned entries. In order:
    /// entries older than `maxAge`; then the oldest unpinned entries while there are more than
    /// `maxItems`; then the oldest unpinned entries while their stored bytes exceed `maxTotalBytes`.
    @discardableResult
    public mutating func enforce(limits: ClipboardLimits, now: Date) -> [ClipboardItem] {
        var evicted: [ClipboardItem] = []

        // Oldest first = from the end of the newest-first list.
        let tooOld = items.reversed().filter { !$0.pinned && now.timeIntervalSince($0.date) > limits.maxAge }
        for item in tooOld { _ = remove(id: item.id) }
        evicted.append(contentsOf: tooOld)

        // Budgets are measured over the unpinned entries only.
        var total = items.reduce(0) { $0 + ($1.pinned ? 0 : $1.byteSize) }
        var count = items.reduce(0) { $0 + ($1.pinned ? 0 : 1) }
        for item in items.reversed() where !item.pinned {
            guard count > limits.maxItems || total > limits.maxTotalBytes else { break }
            _ = remove(id: item.id)
            evicted.append(item)
            count -= 1
            total -= item.byteSize
        }
        return evicted
    }
}
