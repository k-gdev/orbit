import Foundation

/// A small cache whose entries expire `lifetime` seconds after they were stored, holding at most `capacity`
/// entries (the oldest goes first). Window thumbnails use it so hovering the same Dock icon twice in a row
/// doesn't capture every window again. Time is passed in, so it can be tested.
public struct TimedCache<Key: Hashable, Value> {
    public let lifetime: TimeInterval
    public let capacity: Int

    private var entries: [Key: (value: Value, stored: Date)] = [:]

    public init(lifetime: TimeInterval, capacity: Int) {
        self.lifetime = lifetime
        self.capacity = max(capacity, 1)
    }

    public var count: Int { entries.count }

    /// The value stored for `key`, unless it has expired (an expired entry is removed).
    public mutating func value(for key: Key, now: Date) -> Value? {
        guard let entry = entries[key] else { return nil }
        guard now.timeIntervalSince(entry.stored) <= lifetime else {
            entries[key] = nil
            return nil
        }
        return entry.value
    }

    /// Stores `value` (replacing any older one and restarting its lifetime), dropping expired entries and,
    /// past `capacity`, the oldest.
    public mutating func insert(_ value: Value, for key: Key, now: Date) {
        entries = entries.filter { now.timeIntervalSince($0.value.stored) <= lifetime }
        entries[key] = (value, now)
        while entries.count > capacity, let oldest = entries.min(by: { $0.value.stored < $1.value.stored })?.key {
            entries[oldest] = nil
        }
    }

    public mutating func removeAll() {
        entries.removeAll()
    }
}
