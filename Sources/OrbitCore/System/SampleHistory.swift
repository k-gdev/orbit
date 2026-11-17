import Foundation

/// A fixed-capacity ring buffer of the most recent samples (a sparkline's points). Appending past the
/// capacity drops the oldest sample.
public struct SampleHistory<T> {
    /// The most samples kept (at least 1).
    public let capacity: Int
    private var storage: [T] = []
    /// Where the oldest sample sits once the buffer is full.
    private var head = 0

    public init(capacity: Int = 60) {
        self.capacity = max(capacity, 1)
        storage.reserveCapacity(self.capacity)
    }

    public mutating func append(_ value: T) {
        if storage.count < capacity {
            storage.append(value)
        } else {
            storage[head] = value
            head = (head + 1) % capacity
        }
    }

    /// Every kept sample, oldest first.
    public var values: [T] { Array(storage[head...] + storage[..<head]) }

    /// The newest sample.
    public var latest: T? {
        guard !storage.isEmpty else { return nil }
        return storage[(head + storage.count - 1) % storage.count]
    }

    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }

    public mutating func removeAll() {
        storage.removeAll(keepingCapacity: true)
        head = 0
    }
}

extension SampleHistory: Equatable where T: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.capacity == rhs.capacity && lhs.values == rhs.values
    }
}

extension SampleHistory: Sendable where T: Sendable {}

/// The vertical scale of a 0...1 sparkline: a quarter of headroom over the peak, never below 50 % (so a
/// quiet machine still shows a shape rather than a flat line on the floor) and never above 100 %.
public enum SparklineScale {
    public static func ceiling(for values: [Double]) -> Double {
        let peak = values.filter(\.isFinite).max() ?? 0
        return min(max(peak * 1.25, 0.5), 1)
    }
}
