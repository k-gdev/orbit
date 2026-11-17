import Combine
import Foundation
import OrbitCore

/// The System feature's live model. It samples only while the System tab is visible (every
/// `sampleInterval`, everything) or while the menu bar readout is on (every 2 s, only what the readout
/// shows): `SamplingPlan` decides, and with no plan there is no engine at all: no timer, no queue work, no
/// sensor client, no SMC connection.
@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var readings: SystemReadings
    /// "Apple M5 Max", for the processor section header. Read when the tab first shows.
    @Published private(set) var chipName: String?
    /// The GPU's core count. Read when the tab first shows.
    @Published private(set) var gpuCores: Int?

    private let isFixture: Bool
    private var staticInfoLoaded = false
    private var panelVisible = false
    private var readout: MenuBarReadout = .off
    private var panelInterval: TimeInterval
    private var engine: SamplingEngine?
    /// Bumped whenever the engine is replaced, so a late delivery from an old one is ignored.
    private var generation = 0

    /// Cheap: reads nothing until the tab shows or the readout turns on.
    init(sampleInterval: TimeInterval) {
        readings = SystemReadings()
        panelInterval = sampleInterval
        isFixture = false
    }

    /// A monitor that shows `readings` and never samples (snapshots).
    static func fixture(_ readings: SystemReadings, chipName: String?, gpuCores: Int?) -> SystemMonitor {
        SystemMonitor(fixture: readings, chipName: chipName, gpuCores: gpuCores)
    }

    private init(fixture: SystemReadings, chipName: String?, gpuCores: Int?) {
        readings = fixture
        self.chipName = chipName
        self.gpuCores = gpuCores
        panelInterval = 1
        isFixture = true
    }

    /// Whether anything is being sampled right now.
    var isSampling: Bool { engine != nil }

    func setPanelVisible(_ visible: Bool) {
        guard visible != panelVisible else { return }
        panelVisible = visible
        if visible && !staticInfoLoaded && !isFixture {
            staticInfoLoaded = true
            chipName = SystemInfo.chipName()
            gpuCores = GPUSampler.coreCount()
        }
        reconfigure()
    }

    func setReadout(_ readout: MenuBarReadout) {
        guard readout != self.readout else { return }
        self.readout = readout
        reconfigure()
    }

    func setPanelInterval(_ interval: TimeInterval) {
        guard interval != panelInterval else { return }
        panelInterval = interval
        reconfigure()
    }

    /// Stops all sampling (the feature was turned off or Orbit is quitting).
    func stopAll() {
        panelVisible = false
        readout = .off
        reconfigure()
    }

    private func reconfigure() {
        guard !isFixture else { return }
        guard let plan = SamplingPlan.make(panelVisible: panelVisible, readout: readout, panelInterval: panelInterval) else {
            engine?.stop()
            engine = nil
            generation += 1
            return
        }
        if engine == nil {
            generation += 1
            let token = generation
            engine = SamplingEngine(layout: SystemInfo.clusterLayout()) { [weak self] sample, date, interval in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == token else { return }
                        self.apply(sample, at: date, interval: interval)
                    }
                }
            }
        }
        engine?.run(plan)
    }

    private func apply(_ sample: SystemSample, at date: Date, interval: TimeInterval) {
        var next = readings
        next.apply(sample, layout: engine?.layout ?? ClusterLayout(levels: []), at: date, interval: interval)
        readings = next
    }
}

/// Runs the samplers on a private serial queue under a `SamplingPlan`. Every sampler is touched only on
/// that queue. `stop()` cancels the timer and closes the sensor client and SMC connection.
final class SamplingEngine: @unchecked Sendable {
    let layout: ClusterLayout
    /// `.workItem` drains the autorelease pool after every tick (the CF/IOKit copies are bridged objects).
    private let queue = DispatchQueue(label: "com.kevo.orbit.system.sampling", qos: .utility, autoreleaseFrequency: .workItem)
    private let deliver: @Sendable (SystemSample, Date, TimeInterval) -> Void

    // Queue-confined state.
    private var timer: DispatchSourceTimer?
    private var plan: SamplingPlan?
    private let cpu = CPUSampler()
    private let gpu = GPUSampler()
    private let memory = MemorySampler()
    private let thermal = ThermalSampler()
    private let battery = BatterySampler()
    private var lastCPU: Date?
    private var lastBatteryRefresh: Date?

    init(layout: ClusterLayout, deliver: @escaping @Sendable (SystemSample, Date, TimeInterval) -> Void) {
        self.layout = layout
        self.deliver = deliver
    }

    deinit { timer?.cancel() }

    /// Starts sampling under `plan` (first tick at once), or switches to it. Samplers whose metric left the
    /// plan let go of what they hold (closing the tab with the CPU readout on closes the IOHID client, the SMC
    /// connection and the accelerator service).
    func run(_ plan: SamplingPlan) {
        queue.async { [self] in
            guard plan != self.plan else { return }
            release(SamplingPlan.droppedMetrics(from: self.plan, to: plan))
            self.plan = plan
            timer?.cancel()
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: plan.interval, leeway: .milliseconds(Int(plan.interval * 100)))
            source.setEventHandler { [weak self] in self?.tick() }
            timer = source
            source.resume()
        }
    }

    func stop() {
        queue.async { [self] in
            timer?.cancel()
            timer = nil
            release(SamplingPlan.droppedMetrics(from: plan, to: nil))
            plan = nil
            // Whatever the last plan was, nothing stays open once stopped.
            thermal.close()
            gpu.close()
        }
    }

    /// Closes what the samplers of `metrics` hold open; they reopen on their next sample.
    private func release(_ metrics: Set<SystemMetric>) {
        if metrics.contains(.temperature) { thermal.close() }
        if metrics.contains(.gpu) { gpu.close() }
        if metrics.contains(.cpu) { cpu.reset() }
        if metrics.contains(.batteries) { lastBatteryRefresh = nil }
    }

    private func tick() {
        guard let plan else { return }
        let now = Date()
        var sample = SystemSample()
        if plan.metrics.contains(.cpu) {
            if SamplingPlan.isGap(since: lastCPU, now: now, interval: plan.interval) { cpu.reset() }
            sample.cpu = cpu.sample()
            lastCPU = now
            // That was only a baseline: take the first real reading half a second later rather than a whole
            // interval later (2 s for the readout).
            if sample.cpu == nil { scheduleFirstCPUReading() }
        }
        if plan.metrics.contains(.gpu) { sample.gpu = gpu.sample() }
        if plan.metrics.contains(.memory) { sample.memory = memory.sample() }
        if plan.metrics.contains(.temperature) { sample.sensors = thermal.sample() }
        if plan.metrics.contains(.uptime) { sample.uptime = SystemInfo.uptime(now: now) }
        if plan.metrics.contains(.batteries), SamplingPlan.isBatteryRefreshDue(lastRefresh: lastBatteryRefresh, now: now) {
            sample.batteries = battery.sample()
            lastBatteryRefresh = now
        }
        deliver(sample, now, plan.interval)
    }

    private func scheduleFirstCPUReading() {
        guard let interval = plan?.interval else { return }
        queue.asyncAfter(deadline: .now() + min(0.5, interval / 2)) { [weak self] in
            guard let self, let plan = self.plan, plan.metrics.contains(.cpu), let load = self.cpu.sample() else { return }
            let now = Date()
            self.lastCPU = now
            self.deliver(SystemSample(cpu: load), now, plan.interval)
        }
    }
}
