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

    /// The most bytes of a not-yet-converted image (TIFF, usually) worth reading and converting: ten
    /// times the stored limit. An image is judged by the PNG that would be stored, and an uncompressed
    /// TIFF is far bigger than its PNG; this only keeps absurd sizes from being converted at all.
    public var maxRawImageBytes: Int {
        maxItemBytes > Int.max / 10 ? Int.max : maxItemBytes * 10
    }

    /// Whether a copy of `byteSize` bytes may be recorded.
    public func allowsItem(ofSize byteSize: Int) -> Bool {
        byteSize <= maxItemBytes
    }
}

extension ClipboardHistory {
    /// How many copied passwords are kept (newest first). They live in memory only, outside the saved budgets.
    public static let maxConcealedItems = 20

    /// Applies the limits and returns the evicted entries (so their blobs can be deleted), oldest
    /// first. Pinned entries are exempt from every limit: they are never evicted and they do not count
    /// toward the count or size budgets (otherwise enough pins would leave no room, and every new copy
    /// would be stored and evicted at once). Copied passwords don't count either (they would push saved
    /// entries off the disk, and vanish themselves at quit); they have their own cap, `maxConcealedItems`.
    /// In order: entries older than `maxAge`; then the oldest passwords past their cap; then the oldest
    /// saved unpinned entries while there are more than `maxItems`; then while their stored bytes exceed
    /// `maxTotalBytes`.
    @discardableResult
    public mutating func enforce(limits: ClipboardLimits, now: Date) -> [ClipboardItem] {
        var evicted: [ClipboardItem] = []

        // Oldest first = from the end of the newest-first list.
        let tooOld = items.reversed().filter { !$0.pinned && now.timeIntervalSince($0.date) > limits.maxAge }
        for item in tooOld { _ = remove(id: item.id) }
        evicted.append(contentsOf: tooOld)

        let concealed = items.filter(\.concealed)
        let extraConcealed = Array(concealed.dropFirst(Self.maxConcealedItems).reversed())
        for item in extraConcealed { _ = remove(id: item.id) }
        evicted.append(contentsOf: extraConcealed)

        // Budgets are measured over the saved unpinned entries only.
        let counted: (ClipboardItem) -> Bool = { !$0.pinned && !$0.concealed }
        var total = items.reduce(0) { $0 + (counted($1) ? $1.byteSize : 0) }
        var count = items.reduce(0) { $0 + (counted($1) ? 1 : 0) }
        for item in items.reversed() where counted(item) {
            guard count > limits.maxItems || total > limits.maxTotalBytes else { break }
            _ = remove(id: item.id)
            evicted.append(item)
            count -= 1
            total -= item.byteSize
        }
        return evicted
    }
}
