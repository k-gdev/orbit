import Foundation
import Testing
@testable import OrbitCore

/// The System feature's pure logic: CPU load and clusters, sparkline history, memory, temperature
/// sensors, batteries, uptime, settings and when sampling runs.
@Suite struct SystemTests {
    // MARK: CPU

    @Test func cpuLoadFromTicks() {
        let before = [CPUTicks(user: 100, system: 50, idle: 800, nice: 50),
                      CPUTicks(user: 0, system: 0, idle: 1000, nice: 0)]
        // Core 0: 60 busy of 100; core 1: 10 busy of 40.
        let after = [CPUTicks(user: 140, system: 60, idle: 840, nice: 60),
                     CPUTicks(user: 5, system: 5, idle: 1030, nice: 0)]
        let load = CPULoad(previous: before, current: after)
        #expect(load.perCore.count == 2)
        #expect(abs(load.perCore[0] - 0.6) < 1e-9)
        #expect(abs(load.perCore[1] - 0.25) < 1e-9)
        // Total weights every tick on every core: 70 busy of 140.
        #expect(abs(load.total - 0.5) < 1e-9)

        // Counters that wrapped past UInt32.max still give the right delta.
        let wrapped = CPULoad(previous: [CPUTicks(user: UInt32.max - 9, system: 0, idle: 0, nice: 0)],
                              current: [CPUTicks(user: 10, system: 0, idle: 20, nice: 0)])
        #expect(abs(wrapped.total - 0.5) < 1e-9)

        // A core count that changed between snapshots compares only the cores both have.
        let shrunk = CPULoad(previous: before, current: Array(after.prefix(1)))
        #expect(shrunk.perCore.count == 1)
    }

    @Test func cpuLoadZeroDeltaIsZero() {
        let ticks = [CPUTicks(user: 10, system: 10, idle: 10, nice: 10)]
        let load = CPULoad(previous: ticks, current: ticks)
        #expect(load.total == 0)
        #expect(load.perCore == [0])
        #expect(CPULoad(previous: [], current: []).total == 0)
        #expect(CPULoad(previous: [], current: []).perCore.isEmpty)
    }

    @Test func clustersSplitByPerfLevel() {
        // M5 Max: hw.perflevel0 "Super" (6), hw.perflevel1 "Performance" (12). The kernel numbers the
        // slowest level first: cpu0-11 are the Performance cores, cpu12-17 the Super cores.
        let m5 = ClusterLayout([(name: "Super", logicalCPUs: 6), (name: "Performance", logicalCPUs: 12)])
        #expect(m5.coreCount == 18)
        let perCore = Array(repeating: 0.1, count: 12) + Array(repeating: 0.9, count: 6)
        let clusters = m5.clusters(perCore)
        #expect(clusters.map(\.name) == ["Super", "Performance"])
        #expect(clusters.map(\.cores.count) == [6, 12])
        #expect(abs(clusters[0].average - 0.9) < 1e-9)
        #expect(abs(clusters[1].average - 0.1) < 1e-9)

        // M1: perflevel0 "Performance" (4), perflevel1 "Efficiency" (4); cpu0-3 are Efficiency.
        let m1 = ClusterLayout([(name: "Performance", logicalCPUs: 4), (name: "Efficiency", logicalCPUs: 4)])
        let m1Clusters = m1.clusters([0.2, 0.2, 0.2, 0.2, 0.5, 0.6, 0.7, 0.8])
        #expect(m1Clusters.map(\.name) == ["Performance", "Efficiency"])
        #expect(m1Clusters[0].cores == [0.5, 0.6, 0.7, 0.8])
        #expect(abs(m1Clusters[0].average - 0.65) < 1e-9)
        #expect(m1Clusters[1].cores == [0.2, 0.2, 0.2, 0.2])

        // Loads that don't match the layout (or no perf levels at all, as on Intel) make one "CPU" cluster.
        #expect(m1.clusters([0.5, 0.5]).map(\.name) == ["CPU"])
        #expect(ClusterLayout([]).clusters([0.25, 0.75]) == [ClusterLoad(name: "CPU", cores: [0.25, 0.75])])
        #expect(ClusterLayout([]).clusters([]).isEmpty)
    }

    // MARK: History

    @Test func historyCapsAndOrders() {
        var history = SampleHistory<Int>(capacity: 3)
        #expect(history.isEmpty)
        #expect(history.values == [])
        #expect(history.latest == nil)
        history.append(1)
        history.append(2)
        #expect(history.values == [1, 2])
        history.append(3)
        history.append(4)
        history.append(5)
        // Oldest first, never more than the capacity.
        #expect(history.values == [3, 4, 5])
        #expect(history.count == 3)
        #expect(history.latest == 5)
        history.removeAll()
        #expect(history.isEmpty)
        history.append(9)
        #expect(history.values == [9])

        #expect(SampleHistory<Double>().capacity == 60)
        var big = SampleHistory<Double>()
        for i in 0..<150 { big.append(Double(i)) }
        #expect(big.values.count == 60)
        #expect(big.values.first == 90)
        #expect(big.values.last == 149)
        #expect(SampleHistory<Int>(capacity: 2) == SampleHistory<Int>(capacity: 2))
        // A capacity below one still keeps the latest sample.
        var tiny = SampleHistory<Int>(capacity: 0)
        tiny.append(1)
        tiny.append(2)
        #expect(tiny.values == [2])
    }

    @Test func sparklineCeiling() {
        // A quiet machine still shows a shape: the top is at least 50 %, with headroom over the peak.
        #expect(SparklineScale.ceiling(for: []) == 0.5)
        #expect(SparklineScale.ceiling(for: [0.1, 0.2]) == 0.5)
        #expect(abs(SparklineScale.ceiling(for: [0.2, 0.6]) - 0.75) < 1e-9)
        #expect(SparklineScale.ceiling(for: [0.9]) == 1)
        #expect(SparklineScale.ceiling(for: [1.4]) == 1)
        #expect(SparklineScale.ceiling(for: [.nan, 0.1]) == 0.5)
    }

    // MARK: Memory

    @Test func memoryUsedAndPressure() {
        let gib: UInt64 = 1 << 30
        // 16 KB pages: 1 GiB = 65 536 pages.
        let stats = MemoryStats(pageSize: 16_384, free: 65_536, active: 3 * 65_536, inactive: 2 * 65_536,
                                wired: 65_536, compressed: 65_536 / 2, totalBytes: 16 * gib, pressure: MemoryPressure(kernelLevel: 1))
        // Used = active + wired + compressed.
        #expect(stats.usedBytes == 4 * gib + gib / 2)
        #expect(stats.totalBytes == 16 * gib)
        #expect(abs(stats.usedFraction - 4.5 / 16) < 1e-9)
        #expect(stats.pressure == .normal)

        #expect(MemoryPressure(kernelLevel: 1) == .normal)
        #expect(MemoryPressure(kernelLevel: 2) == .warning)
        #expect(MemoryPressure(kernelLevel: 4) == .critical)
        #expect(MemoryPressure(kernelLevel: 0) == .normal)
        #expect(MemoryPressure.allCases.map(\.title) == ["Normal", "Warning", "Critical"])

        // Never more than all of it, and no division by zero.
        let odd = MemoryStats(pageSize: 4096, free: 0, active: 10, inactive: 0, wired: 0, compressed: 0, totalBytes: 0, pressure: .normal)
        #expect(odd.usedFraction == 0)
        let over = MemoryStats(pageSize: 4096, free: 0, active: 1000, inactive: 0, wired: 0, compressed: 0, totalBytes: 4096, pressure: .warning)
        #expect(over.usedFraction == 1)
    }

    @Test func systemFormatting() {
        let gib: UInt64 = 1 << 30
        #expect(SystemFormat.gigabytes(128 * gib) == "128 GB")
        #expect(SystemFormat.gigabytes(62 * gib + gib / 10 * 2) == "62.2 GB")
        #expect(SystemFormat.gigabytes(gib / 2) == "0.5 GB")
        #expect(SystemFormat.gigabytes(0) == "0 GB")
        #expect(SystemFormat.memory(used: 41 * gib, total: 128 * gib) == "41 of 128 GB")
        #expect(SystemFormat.memory(used: 41 * gib + gib / 2, total: 128 * gib) == "41.5 of 128 GB")
        #expect(SystemFormat.percent(0.234) == "23%")
        #expect(SystemFormat.percent(0.996) == "100%")
        #expect(SystemFormat.percent(-0.1) == "0%")
        #expect(SystemFormat.percent(1.4) == "100%")
        #expect(SystemFormat.celsius(53.4) == "53°")
        #expect(SystemFormat.celsius(nil) == "—")
    }

    // MARK: Temperatures

    @Test func sensorClassification() {
        // Present on Kevo's M5 Max (IOHID, PrimaryUsagePage 0xff00 / Usage 5): "PMU tdie1"…"PMU tdie14" (×3),
        // "PMU tdev1"…"PMU tdev8" (read −9201), "PMU tcal" (×3), "NAND CH0 temp", "gas gauge battery".
        #expect(SensorGroups.classify("PMU tdie1") == .soc)
        #expect(SensorGroups.classify("PMU tdie14") == .soc)
        #expect(SensorGroups.classify("PMU tcal") == nil)        // a calibration reference, not a die temperature
        #expect(SensorGroups.classify("PMU tdev3") == nil)       // board thermistors (and garbage on the M5 Max)
        #expect(SensorGroups.classify("NAND CH0 temp") == nil)
        #expect(SensorGroups.classify("gas gauge battery") == nil)
        // And its SMC float keys: 23 × "Tp??" (CPU) and 84 × "Tg??" (GPU); "TG0B" there is not a temperature.
        #expect(SensorGroups.classify("Tp00") == .cpu)
        #expect(SensorGroups.classify("Tp1g") == .cpu)
        #expect(SensorGroups.classify("Te05") == .cpu)
        #expect(SensorGroups.classify("Tg0C") == .gpu)
        #expect(SensorGroups.classify("Tg7L") == .gpu)
        #expect(["TG0B", "TB0T", "Tm00", "Ts0P", "TCMb", "TCHP", "TAOL"].allSatisfy { SensorGroups.classify($0) == nil })
        // Older Apple Silicon names over IOHID (M1/M2).
        #expect(SensorGroups.classify("pACC MTR Temp Sensor2") == .cpu)
        #expect(SensorGroups.classify("eACC MTR Temp Sensor0") == .cpu)
        #expect(SensorGroups.classify("GPU MTR Temp Sensor1") == .gpu)
        #expect(SensorGroups.classify("SOC MTR Temp Sensor0") == .soc)
        #expect(SensorGroups.classify("ANE MTR Temp Sensor1") == .soc)
        #expect(SensorGroups.classify("ISP MTR Temp Sensor5") == .soc)
        // Intel SMC keys.
        #expect(SensorGroups.classify("TC0P") == .cpu)
        #expect(SensorGroups.classify("TC0D") == .cpu)
        #expect(SensorGroups.classify("TC3C") == .cpu)
        #expect(SensorGroups.classify("TG0P") == .gpu)
        #expect(SensorGroups.classify("TG0D") == .gpu)
        #expect(SensorGroups.classify("TPCD") == .soc)
        #expect(SensorGroups.classify("") == nil)
        #expect(SensorGroups.classify("Something else") == nil)

        let groups = SensorGroups(readings: [
            SensorReading(name: "Tp00", celsius: 50), SensorReading(name: "Tp04", celsius: 56),
            SensorReading(name: "Tg08", celsius: 49), SensorReading(name: "Tg0C", celsius: 51),
            SensorReading(name: "PMU tdie1", celsius: 53), SensorReading(name: "PMU tdie1", celsius: 55),
            SensorReading(name: "PMU tcal", celsius: 51.82), SensorReading(name: "gas gauge battery", celsius: 33),
        ])
        #expect(groups.cpu == SensorGroupStats(average: 53, maximum: 56, count: 2))
        #expect(groups.gpu == SensorGroupStats(average: 50, maximum: 51, count: 2))
        #expect(groups.soc == SensorGroupStats(average: 54, maximum: 55, count: 2))
        #expect(groups[.gpu] == groups.gpu)
        #expect(groups.headline == 53)
        #expect(SensorKind.allCases.map(\.title) == ["CPU", "GPU", "SoC"])
        // Without CPU sensors the headline falls back to the SoC die.
        #expect(SensorGroups(readings: [SensorReading(name: "PMU tdie2", celsius: 47)]).headline == 47)
        #expect(SensorGroups(readings: []).headline == nil)
        #expect(SensorGroups(readings: []).isEmpty)
    }

    @Test func sensorIgnoresImplausible() {
        let groups = SensorGroups(readings: [
            SensorReading(name: "PMU tdie1", celsius: -9201.14),
            SensorReading(name: "PMU tdie2", celsius: 0),
            SensorReading(name: "PMU tdie3", celsius: 150),
            SensorReading(name: "PMU tdie4", celsius: .nan),
            SensorReading(name: "PMU tdie5", celsius: .infinity),
            SensorReading(name: "PMU tdie6", celsius: 48),
            SensorReading(name: "Tg00", celsius: 212),
        ])
        #expect(groups.soc == SensorGroupStats(average: 48, maximum: 48, count: 1))
        #expect(groups.gpu == nil)
        #expect(groups.cpu == nil)
        #expect(SensorGroups.isPlausible(0.5))
        #expect(SensorGroups.isPlausible(149.9))
        #expect(!SensorGroups.isPlausible(0))
        #expect(!SensorGroups.isPlausible(150))
    }

    @Test func heatLevels() {
        #expect(HeatLevel(celsius: 45) == .normal)
        #expect(HeatLevel(celsius: 79.9) == .normal)
        #expect(HeatLevel(celsius: 80) == .warm)
        #expect(HeatLevel(celsius: 94.9) == .warm)
        #expect(HeatLevel(celsius: 95) == .hot)
        #expect(HeatLevel(celsius: nil) == .normal)
        #expect(HeatLevel(celsius: .nan) == .normal)
    }

    @Test func smcDecoding() {
        #expect(SMCCode.code("TC0P") == 0x5443_3050)
        #expect(SMCCode.string(0x5443_3050) == "TC0P")
        #expect(SMCCode.string(SMCCode.code("flt ")) == "flt ")
        // Apple Silicon: little-endian Float32.
        let bytes = withUnsafeBytes(of: Float(49.58).bitPattern.littleEndian) { Array($0) }
        #expect(abs((SMCCode.celsius(type: "flt ", bytes: bytes) ?? 0) - 49.58) < 0.001)
        // Intel: big-endian signed 8.8 fixed point.
        #expect(SMCCode.celsius(type: "sp78", bytes: [0x2F, 0x80]) == 47.5)
        #expect(SMCCode.celsius(type: "sp78", bytes: [0xFF, 0x00]) == -1)
        // Anything else, or the wrong size, is not a temperature.
        #expect(SMCCode.celsius(type: "ioft", bytes: [0, 0, 0, 0, 0, 0, 0, 0]) == nil)
        #expect(SMCCode.celsius(type: "flt ", bytes: [0, 0]) == nil)
        #expect(SMCCode.celsius(type: "sp78", bytes: [1]) == nil)
    }

    // MARK: Uptime

    @Test func uptimeStrings() {
        let minute = 60.0, hour = 3600.0, day = 86_400.0
        #expect(UptimeFormatter.string(seconds: 3 * day + 4 * hour + 59 * minute) == "3 d 4 h")
        #expect(UptimeFormatter.string(seconds: 5 * hour + 12 * minute + 30) == "5 h 12 m")
        #expect(UptimeFormatter.string(seconds: 12 * minute + 59) == "12 m")
        #expect(UptimeFormatter.string(seconds: 1 * day) == "1 d 0 h")
        #expect(UptimeFormatter.string(seconds: 1 * hour) == "1 h 0 m")
        #expect(UptimeFormatter.string(seconds: 59) == "< 1 m")
        #expect(UptimeFormatter.string(seconds: 0) == "< 1 m")
        #expect(UptimeFormatter.string(seconds: -5) == "< 1 m")
        #expect(UptimeFormatter.string(seconds: .nan) == "< 1 m")
        #expect(UptimeFormatter.string(seconds: 400 * day) == "400 d 0 h")
    }

    // MARK: Batteries

    /// The internal battery as `IOPSGetPowerSourceDescription` reports it on Kevo's Mac (on AC, full).
    private static let internalBattery: [String: Any] = [
        "Type": "InternalBattery", "Name": "InternalBattery-0", "Transport Type": "Internal",
        "Current Capacity": 100, "Max Capacity": 100, "Is Charging": false, "Is Charged": true, "Is Present": true,
        "Power Source State": "AC Power", "Time to Empty": 0, "Time to Full Charge": 0, "Power Source ID": 25_952_355,
    ]

    @Test func batteryParsesInternal() throws {
        let full = try #require(BatteryParser.powerSources([Self.internalBattery]).first)
        #expect(full.kind == .mac)
        #expect(full.id == "internal")
        #expect(full.percent == 100)
        #expect(full.isCharged)
        #expect(full.onPowerAdapter)
        #expect(full.statusText == "Charged")

        var charging = Self.internalBattery
        charging["Current Capacity"] = 62
        charging["Is Charging"] = true
        charging["Is Charged"] = false
        charging["Time to Full Charge"] = 65
        let c = try #require(BatteryParser.powerSources([charging]).first)
        #expect(c.percent == 62)
        #expect(c.isCharging)
        #expect(c.minutesToFull == 65)
        #expect(c.statusText == "Charging · 1 h 5 m to full")

        var onBattery = Self.internalBattery
        onBattery["Current Capacity"] = 41
        onBattery["Is Charged"] = false
        onBattery["Power Source State"] = "Battery Power"
        onBattery["Time to Empty"] = 200
        let b = try #require(BatteryParser.powerSources([onBattery]).first)
        #expect(!b.onPowerAdapter)
        #expect(b.minutesToEmpty == 200)
        #expect(b.statusText == "3 h 20 m left")
        onBattery["Time to Empty"] = -1   // still calculating
        #expect(BatteryParser.powerSources([onBattery]).first?.statusText == "On battery")

        // Plugged in but held below full (optimised charging).
        var held = Self.internalBattery
        held["Current Capacity"] = 80
        held["Is Charged"] = false
        #expect(BatteryParser.powerSources([held]).first?.statusText == "Not charging")

        // Capacity in mAh rather than percent still gives a percentage; an absent battery gives nothing.
        var mAh = Self.internalBattery
        mAh["Current Capacity"] = 3000
        mAh["Max Capacity"] = 6000
        #expect(BatteryParser.powerSources([mAh]).first?.percent == 50)
        var absent = Self.internalBattery
        absent["Is Present"] = false
        #expect(BatteryParser.powerSources([absent]).isEmpty)
        #expect(BatteryParser.powerSources([["Name": "junk"]]).isEmpty)
    }

    @Test func batteryParsesBluetoothAndDedupes() throws {
        // Accessory power sources (IOPSCopyPowerSourcesByType) as they appear on Kevo's Mac.
        let keyboard: [String: Any] = [
            "Type": "Accessory Source", "Name": "MX KEYS S", "Accessory Category": "Keyboard",
            "Accessory Identifier": "CA256F50", "Current Capacity": 10, "Max Capacity": 100, "Low Warn Level": 20,
            "Power Source State": "Battery Power", "Transport Type": "Bluetooth LE",
        ]
        let airpodsCase: [String: Any] = [
            "Type": "Accessory Source", "Name": "Kevo’s AirPods Case", "Accessory Category": "Audio Battery Case",
            "Accessory Identifier": "7EEB8E78", "Group Identifier": "G1", "Part Identifier": "Case",
            "Current Capacity": 35, "Max Capacity": 100, "Is Charging": false, "Is Present": true,
        ]
        let part = { (side: String, level: Int) -> [String: Any] in
            ["Part Identifier": side, "Current Capacity": level, "Max Capacity": 100, "Is Charging": true]
        }
        let airpods: [String: Any] = [
            "Type": "Accessory Source", "Name": "Kevo’s AirPods", "Accessory Category": "Headset",
            "Accessory Identifier": "D3EDA881", "Group Identifier": "G1", "Part Identifier": "Combined",
            "Current Capacity": 90, "Max Capacity": 100, "Is Charging": true, "Is Present": true,
            "Combined Parts": [part("Left", 100), part("Right", 90)],
        ]
        // IORegistry HID devices with BatteryPercent: one mouse seen twice (same address, different case and
        // separators), a trackpad, and a keyboard that is also an IOPS accessory.
        let registry: [[String: Any]] = [
            ["Product": "Magic Mouse", "BatteryPercent": 64, "DeviceAddress": "a4-83-e7-11-22-33"],
            ["Product": "Magic Mouse", "BatteryPercent": 64, "DeviceAddress": "A4:83:E7:11:22:33"],
            ["Product": "Magic Trackpad", "BatteryPercent": 88, "DeviceAddress": "a4-83-e7-44-55-66"],
            ["Product": "MX Keys S", "BatteryPercent": 10, "DeviceAddress": "c0-ff-ee-00-00-01"],
            ["Product": "Apple Internal Keyboard / Trackpad"],   // no battery level: skipped
        ]
        let all = BatteryParser.readings(powerSources: [keyboard, airpodsCase, Self.internalBattery, airpods], registry: registry)
        // The Mac first, then devices by name; the case folds into its AirPods; the registry keyboard and the
        // repeated mouse are dropped.
        #expect(all.map(\.name) == ["This Mac", "Kevo’s AirPods", "Magic Mouse", "Magic Trackpad", "MX KEYS S"])
        #expect(all.map(\.kind) == [.mac, .headphones, .mouse, .trackpad, .keyboard])

        let pods = all[1]
        #expect(pods.percent == 90)
        #expect(pods.isCharging)
        #expect(pods.parts == [BatteryReading.Part(name: "L", percent: 100), BatteryReading.Part(name: "R", percent: 90),
                               BatteryReading.Part(name: "Case", percent: 35)])
        #expect(pods.statusText == "L 100% · R 90% · Case 35%")
        #expect(all[2].id == "bt:a4:83:e7:11:22:33")
        #expect(all[2].percent == 64)
        #expect(all[2].statusText == nil)
        #expect(all[4].isLow)
        #expect(all[4].statusText == "Low battery")
        #expect(!all[3].isLow)

        // A case whose earbuds aren't connected stays on its own row.
        let lonelyCase = BatteryParser.powerSources([airpodsCase])
        #expect(lonelyCase.map(\.name) == ["Kevo’s AirPods Case"])
        #expect(lonelyCase.first?.kind == .headphones)
        // A charging device says so.
        var chargingMouse = keyboard
        chargingMouse["Accessory Category"] = "Mouse"
        chargingMouse["Is Charging"] = true
        #expect(BatteryParser.powerSources([chargingMouse]).first?.statusText == "Charging")
        #expect(BatteryParser.powerSources([chargingMouse]).first?.kind == .mouse)
        // Kinds from names when there is no category.
        #expect(BatteryParser.registryDevices([["Product": "Xbox Wireless Controller", "BatteryPercent": 50]]).first?.kind == .gameController)
        #expect(BatteryParser.registryDevices([["Product": "Beats Studio Buds", "BatteryPercent": 50]]).first?.kind == .headphones)
        #expect(BatteryParser.registryDevices([["Product": "Pen", "BatteryPercent": 50]]).first?.kind == .other)

        // Cross-source de-dup is an exact (case- and apostrophe-insensitive) name match only: a registry device
        // whose name is merely part of a power source's name stays, and so does one with no name.
        let magicKeyboardSource: [String: Any] = [
            "Type": "Accessory Source", "Name": "Kevo’s Magic Keyboard", "Accessory Category": "Keyboard",
            "Accessory Identifier": "AB12", "Current Capacity": 80, "Max Capacity": 100,
        ]
        let loose = BatteryParser.readings(powerSources: [magicKeyboardSource], registry: [
            ["Product": "Magic Keyboard", "BatteryPercent": 79, "DeviceAddress": "aa-bb-cc-dd-ee-01"],
            ["Product": "", "BatteryPercent": 40, "DeviceAddress": "aa-bb-cc-dd-ee-02"],
            ["Product": "kevo's magic keyboard", "BatteryPercent": 80, "DeviceAddress": "aa-bb-cc-dd-ee-03"],
        ])
        #expect(loose.map(\.name) == ["Bluetooth Device", "Kevo’s Magic Keyboard", "Magic Keyboard"])
        #expect(loose.first?.id == "bt:aa:bb:cc:dd:ee:02")
    }

    // MARK: Settings

    @Test func settingsRoundTrip() {
        let (defaults, cleanup) = Fixtures.defaults()
        defer { cleanup() }
        let fresh = SystemSettings(defaults: defaults)
        #expect(fresh.menuBarReadout == .off)
        #expect(fresh.sampleInterval == 1)
        #expect(fresh.showPerCluster)

        fresh.menuBarReadout = .cpuAndTemperature
        fresh.sampleInterval = 2
        fresh.showPerCluster = false
        #expect(defaults.string(forKey: "system.menuBarReadout") == "cpuAndTemperature")
        #expect(defaults.double(forKey: "system.sampleInterval") == 2)
        #expect(defaults.object(forKey: "system.showPerCluster") as? Bool == false)

        let reloaded = SystemSettings(defaults: defaults)
        #expect(reloaded.menuBarReadout == .cpuAndTemperature)
        #expect(reloaded.sampleInterval == 2)
        #expect(!reloaded.showPerCluster)

        // Junk on disk falls back to the defaults; the interval stays within its range.
        defaults.set("sideways", forKey: "system.menuBarReadout")
        defaults.set(0.01, forKey: "system.sampleInterval")
        #expect(SystemSettings(defaults: defaults).menuBarReadout == .off)
        #expect(SystemSettings(defaults: defaults).sampleInterval == SystemSettings.intervalRange.lowerBound)
        defaults.set(3600.0, forKey: "system.sampleInterval")
        #expect(SystemSettings(defaults: defaults).sampleInterval == SystemSettings.intervalRange.upperBound)
        #expect(SystemSettings.intervalChoices == [1, 2, 5])
        #expect(SystemSettings.intervalChoices.allSatisfy(SystemSettings.intervalRange.contains))
    }

    @Test func menuBarReadoutText() {
        #expect(MenuBarReadout.allCases == [.off, .cpu, .temperature, .cpuAndTemperature])
        #expect(MenuBarReadout.allCases.map(\.title) == ["Off", "CPU load", "Temperature", "CPU load and temperature"])
        #expect(MenuBarReadout.off.text(cpu: 0.2, celsius: 50) == nil)
        #expect(MenuBarReadout.cpu.text(cpu: 0.234, celsius: 50) == "CPU 23%")
        #expect(MenuBarReadout.temperature.text(cpu: 0.2, celsius: 53.4) == "53°C")
        #expect(MenuBarReadout.cpuAndTemperature.text(cpu: 0.07, celsius: 53.6) == "7% · 54°C")
        // Before the first sample (or without sensors) a dash holds the place.
        #expect(MenuBarReadout.cpu.text(cpu: nil, celsius: nil) == "CPU —")
        #expect(MenuBarReadout.temperature.text(cpu: nil, celsius: nil) == "—°C")
        #expect(MenuBarReadout.cpuAndTemperature.text(cpu: nil, celsius: nil) == "— · —°C")
        #expect(MenuBarReadout.off.metrics.isEmpty)
        #expect(MenuBarReadout.cpu.metrics == [.cpu])
        #expect(MenuBarReadout.temperature.metrics == [.temperature])
        #expect(MenuBarReadout.cpuAndTemperature.metrics == [.cpu, .temperature])
    }

    // MARK: When sampling runs

    @Test func samplingPlan() {
        // Hidden tab and no readout: nothing runs at all.
        #expect(SamplingPlan.make(panelVisible: false, readout: .off, panelInterval: 1) == nil)
        // The readout alone: every 2 s, only what it shows.
        #expect(SamplingPlan.make(panelVisible: false, readout: .cpu, panelInterval: 1)
                == SamplingPlan(interval: 2, metrics: [.cpu]))
        #expect(SamplingPlan.make(panelVisible: false, readout: .cpuAndTemperature, panelInterval: 1)
                == SamplingPlan(interval: 2, metrics: [.cpu, .temperature]))
        // The System tab visible: everything at the panel's interval, whatever the readout.
        #expect(SamplingPlan.make(panelVisible: true, readout: .off, panelInterval: 1)
                == SamplingPlan(interval: 1, metrics: Set(SystemMetric.allCases)))
        #expect(SamplingPlan.make(panelVisible: true, readout: .temperature, panelInterval: 5)?.interval == 5)
        #expect(SamplingPlan.make(panelVisible: true, readout: .off, panelInterval: 0)?.interval == SystemSettings.intervalRange.lowerBound)

        // Batteries change slowly: refreshed at most every 10 s.
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        #expect(SamplingPlan.isBatteryRefreshDue(lastRefresh: nil, now: now))
        #expect(!SamplingPlan.isBatteryRefreshDue(lastRefresh: now.addingTimeInterval(-9), now: now))
        #expect(SamplingPlan.isBatteryRefreshDue(lastRefresh: now.addingTimeInterval(-10), now: now))

        // A sparkline isn't spliced across a gap (the panel was closed): history restarts after 3 missed samples.
        #expect(!SamplingPlan.isGap(since: nil, now: now, interval: 1))
        #expect(!SamplingPlan.isGap(since: now.addingTimeInterval(-2.5), now: now, interval: 1))
        #expect(SamplingPlan.isGap(since: now.addingTimeInterval(-3.5), now: now, interval: 1))
        #expect(!SamplingPlan.isGap(since: now.addingTimeInterval(-5), now: now, interval: 2))
    }

    @Test func readingsApplySamples() {
        let layout = ClusterLayout([(name: "Super", logicalCPUs: 1), (name: "Performance", logicalCPUs: 2)])
        var readings = SystemReadings()
        #expect(readings.cpu == nil)
        #expect(readings.batteries == nil)
        let t0 = Date(timeIntervalSinceReferenceDate: 0)

        readings.apply(SystemSample(cpu: CPULoad(total: 0.5, perCore: [0.2, 0.4, 0.9]), gpu: 0.19, uptime: 100,
                                    batteries: [BatteryReading(id: "internal", name: "This Mac", kind: .mac, percent: 100)]),
                       layout: layout, at: t0, interval: 1)
        #expect(readings.cpu?.total == 0.5)
        // Performance (cpu0-1) and Super (cpu2), fastest first.
        #expect(readings.clusters.map(\.name) == ["Super", "Performance"])
        #expect(readings.clusters.first?.cores == [0.9])
        #expect(readings.cpuHistory.values == [0.5])
        #expect(readings.gpuHistory.values == [0.19])
        #expect(readings.gpu == 0.19)
        #expect(readings.uptime == 100)
        #expect(readings.batteries?.count == 1)

        // A tick that only measured the CPU keeps every other value as it was.
        readings.apply(SystemSample(cpu: CPULoad(total: 0.25, perCore: [0.25, 0.25, 0.25])), layout: layout,
                       at: t0.addingTimeInterval(1), interval: 1)
        #expect(readings.cpuHistory.values == [0.5, 0.25])
        #expect(readings.gpuHistory.values == [0.19])
        #expect(readings.gpu == 0.19)
        #expect(readings.batteries?.count == 1)
        #expect(readings.uptime == 100)

        // After a gap (panel closed for a minute) the sparklines start over.
        readings.apply(SystemSample(cpu: CPULoad(total: 0.75, perCore: [0.75, 0.75, 0.75]), gpu: 0.4), layout: layout,
                       at: t0.addingTimeInterval(60), interval: 1)
        #expect(readings.cpuHistory.values == [0.75])
        #expect(readings.gpuHistory.values == [0.4])
        #expect(readings.lastSample == t0.addingTimeInterval(60))

        // A slower plan (the readout's 2 s) is not mistaken for a gap.
        readings.apply(SystemSample(cpu: CPULoad(total: 0.5, perCore: [0.5, 0.5, 0.5])), layout: layout,
                       at: t0.addingTimeInterval(65), interval: 2)
        #expect(readings.cpuHistory.values == [0.75, 0.5])

        // The CPU readout keeps ticking every 2 s for an hour with the tab closed: the GPU history is old by
        // then, so the next GPU sample starts it over even though some sample arrived 2 s ago.
        var t = 65.0
        while t < 3665 {
            t += 2
            readings.apply(SystemSample(cpu: CPULoad(total: 0.25, perCore: [0.25, 0.25, 0.25])), layout: layout,
                           at: t0.addingTimeInterval(t), interval: 2)
        }
        readings.apply(SystemSample(cpu: CPULoad(total: 0.3, perCore: [0.3, 0.3, 0.3]), gpu: 0.6), layout: layout,
                       at: t0.addingTimeInterval(t + 1), interval: 1)
        #expect(readings.gpuHistory.values == [0.6])
        // The CPU stream had no gap, so its history kept going (capped at 60).
        #expect(readings.cpuHistory.count == 60)
        #expect(readings.cpuHistory.latest == 0.3)

        // And the other way round: a temperature-only readout doesn't keep the CPU history alive.
        var tempOnly = SystemReadings()
        tempOnly.apply(SystemSample(cpu: CPULoad(total: 0.5, perCore: [0.5, 0.5, 0.5])), layout: layout, at: t0, interval: 1)
        for step in 1...1800 {
            tempOnly.apply(SystemSample(sensors: SensorGroups(cpu: SensorGroupStats(average: 50, maximum: 50, count: 1))),
                           layout: layout, at: t0.addingTimeInterval(Double(step) * 2), interval: 2)
        }
        tempOnly.apply(SystemSample(cpu: CPULoad(total: 0.1, perCore: [0.1, 0.1, 0.1])), layout: layout,
                       at: t0.addingTimeInterval(3601), interval: 1)
        #expect(tempOnly.cpuHistory.values == [0.1])
    }
}
