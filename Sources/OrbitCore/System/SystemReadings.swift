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
    /// When the last sample arrived.
    public var lastSample: Date?
    private var lastInterval: TimeInterval = 0

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

    /// Folds in one tick taken at `now` under a plan sampling every `interval` seconds. The histories start
    /// over after a gap (`SamplingPlan.isGap`) so a sparkline never joins readings minutes apart.
    public mutating func apply(_ sample: SystemSample, layout: ClusterLayout, at now: Date, interval: TimeInterval) {
        if SamplingPlan.isGap(since: lastSample, now: now, interval: max(interval, lastInterval)) {
            cpuHistory.removeAll()
            gpuHistory.removeAll()
        }
        lastSample = now
        lastInterval = interval
        if let load = sample.cpu {
            cpu = load
            clusters = layout.clusters(load.perCore)
            cpuHistory.append(load.total)
        }
        if let utilization = sample.gpu {
            gpu = utilization
            gpuHistory.append(utilization)
        }
        if let memory = sample.memory { self.memory = memory }
        if let sensors = sample.sensors { self.sensors = sensors }
        if let uptime = sample.uptime { self.uptime = uptime }
        if let batteries = sample.batteries { self.batteries = batteries }
    }
}
