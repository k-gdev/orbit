import Foundation

/// What one sampling tick measured. A nil field was not measured this tick (the plan didn't ask for it,
/// or the source is unavailable) and leaves the previous value in place.
public struct SystemSample: Sendable {
    public var cpu: CPULoad?
    /// GPU "Device Utilization", 0...1.
    public var gpu: Double?
    public var memory: MemoryStats?
    public var sensors: SensorGroups?
    /// Seconds since boot.
    public var uptime: TimeInterval?
    public var batteries: [BatteryReading]?

    public init(cpu: CPULoad? = nil, gpu: Double? = nil, memory: MemoryStats? = nil, sensors: SensorGroups? = nil,
                uptime: TimeInterval? = nil, batteries: [BatteryReading]? = nil) {
        self.cpu = cpu
        self.gpu = gpu
        self.memory = memory
        self.sensors = sensors
        self.uptime = uptime
        self.batteries = batteries
    }
}

/// Everything the System tab and the menu bar readout show: the latest values plus the CPU and GPU
/// sparkline histories.
public struct SystemReadings: Equatable, Sendable {
    public var cpu: CPULoad?
    /// The CPU load per cluster, fastest first (empty until the CPU is sampled).
    public var clusters: [ClusterLoad] = []
    public var cpuHistory = SampleHistory<Double>()
    public var gpu: Double?
    public var gpuHistory = SampleHistory<Double>()
    public var memory: MemoryStats?
    public var sensors: SensorGroups?
    public var uptime: TimeInterval?
    /// nil until batteries were read once; empty when there are none.
    public var batteries: [BatteryReading]?
    /// When the last sample (of anything) arrived.
    public var lastSample: Date?
    /// When each history last grew, and under which interval: each is gap-checked against its own time, so a
    /// CPU-only readout ticking every 2 s doesn't keep an hour-old GPU history "fresh" (and vice versa).
    private var cpuAppended: (date: Date, interval: TimeInterval)?
    private var gpuAppended: (date: Date, interval: TimeInterval)?

    public init(cpu: CPULoad? = nil, clusters: [ClusterLoad] = [], cpuHistory: SampleHistory<Double> = SampleHistory(),
                gpu: Double? = nil, gpuHistory: SampleHistory<Double> = SampleHistory(), memory: MemoryStats? = nil,
                sensors: SensorGroups? = nil, uptime: TimeInterval? = nil, batteries: [BatteryReading]? = nil) {
        self.cpu = cpu
        self.clusters = clusters
        self.cpuHistory = cpuHistory
        self.gpu = gpu
        self.gpuHistory = gpuHistory
        self.memory = memory
        self.sensors = sensors
        self.uptime = uptime
        self.batteries = batteries
    }

    /// Folds in one tick taken at `now` under a plan sampling every `interval` seconds. Each history starts
    /// over after a gap in its OWN samples (`SamplingPlan.isGap`), so a sparkline never joins readings minutes
    /// apart, whatever else kept arriving in between.
    public mutating func apply(_ sample: SystemSample, layout: ClusterLayout, at now: Date, interval: TimeInterval) {
        lastSample = now
        if let load = sample.cpu {
            cpu = load
            clusters = layout.clusters(load.perCore)
            Self.append(load.total, to: &cpuHistory, last: &cpuAppended, at: now, interval: interval)
        }
        if let utilization = sample.gpu {
            gpu = utilization
            Self.append(utilization, to: &gpuHistory, last: &gpuAppended, at: now, interval: interval)
        }
        if let memory = sample.memory { self.memory = memory }
        if let sensors = sample.sensors { self.sensors = sensors }
        if let uptime = sample.uptime { self.uptime = uptime }
        if let batteries = sample.batteries { self.batteries = batteries }
    }

    private static func append(_ value: Double, to history: inout SampleHistory<Double>,
                               last: inout (date: Date, interval: TimeInterval)?, at now: Date, interval: TimeInterval) {
        if let previous = last, SamplingPlan.isGap(since: previous.date, now: now, interval: max(interval, previous.interval)) {
            history.removeAll()
        }
        history.append(value)
        last = (now, interval)
    }

    public static func == (lhs: SystemReadings, rhs: SystemReadings) -> Bool {
        lhs.cpu == rhs.cpu && lhs.clusters == rhs.clusters && lhs.cpuHistory == rhs.cpuHistory && lhs.gpu == rhs.gpu
            && lhs.gpuHistory == rhs.gpuHistory && lhs.memory == rhs.memory && lhs.sensors == rhs.sensors
            && lhs.uptime == rhs.uptime && lhs.batteries == rhs.batteries && lhs.lastSample == rhs.lastSample
    }
}
