import OrbitCore
import SwiftUI

/// The System tab: CPU (total, sparkline, a bar per core in each cluster), GPU and memory side by side,
/// temperatures and uptime, then batteries (the Mac's and each connected device's).
struct SystemPanelView: View {
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var settings: SystemSettings

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let readings = monitor.readings
        VStack(alignment: .leading, spacing: 8) {
            PanelSectionHeader("Processor", trailing: monitor.chipName.map { name in
                AnyView(Text(name).font(.system(size: 11, weight: .medium)).foregroundStyle(style.secondaryInk))
            })
            CPUTile(readings: readings, showClusters: settings.showPerCluster)
            HStack(alignment: .top, spacing: 8) {
                GPUTile(readings: readings, cores: monitor.gpuCores)
                MemoryTile(memory: readings.memory)
            }
            .fixedSize(horizontal: false, vertical: true)

            PanelSectionHeader("Temperatures & Uptime")
            HStack(alignment: .top, spacing: 8) {
                TemperatureTile(sensors: readings.sensors)
                UptimeTile(uptime: readings.uptime)
                    .frame(width: 112)
            }
            .fixedSize(horizontal: false, vertical: true)

            PanelSectionHeader("Batteries")
            BatteriesTile(batteries: readings.batteries)
        }
    }

    private var style: PanelStyle { PanelStyle.colors(for: colorScheme) }
}

// MARK: - Tiles

/// A tile's title row: an SF Symbol, the name with an optional detail line under it, and the big value
/// on the right.
private struct TileHeader: View {
    let title: String
    let systemImage: String
    var detail: String?
    var value: String?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PanelStyle.accent(for: colorScheme))
                .frame(width: 16, height: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(style.secondaryInk).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let value {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(style.inkOnTrack)
                    .contentTransition(.numericText())
                    .padding(.top, -3)
            }
        }
    }
}

private struct CPUTile: View {
    let readings: SystemReadings
    let showClusters: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        let accent = PanelStyle.accent(for: colorScheme)
        PanelTile(spacing: 8) {
            TileHeader(title: "CPU", systemImage: "cpu", detail: coresText,
                       value: readings.cpu.map { SystemFormat.percent($0.total) } ?? "—")
            Sparkline(values: readings.cpuHistory.values, capacity: readings.cpuHistory.capacity, color: accent)
                .frame(height: 40)
            if showClusters && readings.clusters.count > 1 {
                VStack(spacing: 6) {
                    ForEach(readings.clusters, id: \.name) { cluster in
                        HStack(spacing: 8) {
                            Text(cluster.name).font(.system(size: 12, weight: .medium)).foregroundStyle(style.secondaryInk)
                                .lineLimit(1)
                                .frame(width: 86, alignment: .leading)
                            CoreBars(loads: cluster.cores, color: accent)
                            Spacer(minLength: 4)
                            Text(SystemFormat.percent(cluster.average))
                                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(style.inkOnTrack)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(cluster.name) cores, \(cluster.cores.count), \(SystemFormat.percent(cluster.average))")
                    }
                }
            }
        }
    }

    /// "18 cores · 2 clusters", or just the core count.
    private var coresText: String? {
        guard let cpu = readings.cpu, !cpu.perCore.isEmpty else { return nil }
        let clusters = readings.clusters.count
        return clusters > 1 ? "\(cpu.perCore.count) cores · \(clusters) clusters" : "\(cpu.perCore.count) cores"
    }
}

private struct GPUTile: View {
    let readings: SystemReadings
    let cores: Int?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        PanelTile(spacing: 8) {
            TileHeader(title: "GPU", systemImage: "square.stack.3d.up.fill", detail: cores.map { "\($0) cores" },
                       value: readings.gpu.map(SystemFormat.percent) ?? "—")
            Spacer(minLength: 0)
            Sparkline(values: readings.gpuHistory.values, capacity: readings.gpuHistory.capacity,
                      color: PanelStyle.accent(for: colorScheme))
                .frame(height: 26)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct MemoryTile: View {
    let memory: MemoryStats?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile(spacing: 8) {
            TileHeader(title: "Memory", systemImage: "memorychip", value: memory.map { SystemFormat.percent($0.usedFraction) } ?? "—")
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 7) {
                MeterBar(fraction: memory?.usedFraction ?? 0, color: pressureColor)
                HStack(spacing: 4) {
                    Text(memory.map { SystemFormat.memory(used: $0.usedBytes, total: $0.totalBytes) } ?? "—")
                        .monospacedDigit()
                        .foregroundStyle(style.inkOnTrack)
                    Spacer(minLength: 2)
                    if let memory {
                        Circle().fill(pressureColor).frame(width: 6, height: 6)
                        Text(memory.pressure.title).foregroundStyle(style.secondaryInk)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .lineLimit(1)
                .help("Memory pressure")
            }
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(memory.map { "Memory \(SystemFormat.memory(used: $0.usedBytes, total: $0.totalBytes)), pressure \($0.pressure.title)" } ?? "Memory")
    }

    private var pressureColor: Color {
        switch memory?.pressure ?? .normal {
        case .normal: PanelStyle.accent(for: colorScheme)
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct TemperatureTile: View {
    let sensors: SensorGroups?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile {
            if let sensors, !sensors.isEmpty {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(SensorKind.allCases, id: \.self) { kind in
                        column(kind, stats: sensors[kind], style: style)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "thermometer.medium").foregroundStyle(style.secondaryInk)
                    Text(sensors == nil ? "Reading sensors…" : "No temperature sensors found")
                        .font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func column(_ kind: SensorKind, stats: SensorGroupStats?, style: PanelStyle) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "thermometer.medium").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(heatColor(stats?.average, style: style))
                Text(kind.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.secondaryInk)
            }
            Text(SystemFormat.celsius(stats?.average))
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(stats == nil ? style.secondaryInk : heatColor(stats?.average, style: style, ink: style.inkOnTrack))
            Text(stats.map { "max \(SystemFormat.celsius($0.maximum))" } ?? "no sensor")
                .font(.system(size: 10.5)).foregroundStyle(style.secondaryInk)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(kind.title) \(stats.map { "\(Int($0.average.rounded())) degrees, maximum \(Int($0.maximum.rounded()))" } ?? "no sensor")")
    }

    private func heatColor(_ celsius: Double?, style: PanelStyle, ink: Color? = nil) -> Color {
        switch HeatLevel(celsius: celsius) {
        case .normal: ink ?? PanelStyle.accent(for: colorScheme)
        case .warm: .orange
        case .hot: .red
        }
    }
}

private struct UptimeTile: View {
    let uptime: TimeInterval?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile(spacing: 2) {
            HStack(spacing: 3) {
                Image(systemName: "clock.arrow.circlepath").font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(PanelStyle.accent(for: colorScheme))
                Text("Uptime").font(.system(size: 11, weight: .semibold)).foregroundStyle(style.secondaryInk)
            }
            Text(uptime.map { UptimeFormatter.string(seconds: $0) } ?? "—")
                .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(style.inkOnTrack)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(uptime.map { "since " + Self.bootText(Date().addingTimeInterval(-$0)) } ?? " ")
                .font(.system(size: 10.5)).foregroundStyle(style.secondaryInk)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    /// "Sat 13:57", or "Oct 3" when it was more than a week ago.
    private static func bootText(_ date: Date) -> String {
        (Date().timeIntervalSince(date) > 6 * 86_400 ? dayFormatter : weekdayTimeFormatter).string(from: date)
    }

    /// Built once, not per render (the tab redraws every second).
    private static let weekdayTimeFormatter = formatter(template: "EEE HH:mm")
    private static let dayFormatter = formatter(template: "MMM d")

    private static func formatter(template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }
}

private struct BatteriesTile: View {
    let batteries: [BatteryReading]?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let style = PanelStyle.colors(for: colorScheme)
        PanelTile(spacing: 0) {
            if let batteries {
                let mac = batteries.filter { $0.kind == .mac }
                let devices = batteries.filter { $0.kind != .mac }
                ForEach(mac) { row($0) }
                if !mac.isEmpty {
                    Divider().padding(.vertical, 6).opacity(0.6)
                }
                if devices.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(style.secondaryInk)
                            .frame(width: 28)
                        Text("No connected device reports a battery level")
                            .font(.system(size: 12)).foregroundStyle(style.secondaryInk)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 2)
                } else {
                    VStack(spacing: 8) { ForEach(devices) { row($0) } }
                }
            } else {
                Text("Reading batteries…").font(.system(size: 12)).foregroundStyle(style.secondaryInk)
            }
        }
    }

    private func row(_ battery: BatteryReading) -> some View {
        let style = PanelStyle.colors(for: colorScheme)
        return HStack(spacing: 8) {
            Image(systemName: Self.symbol(for: battery))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(style.inkOnTrack)
                .frame(width: 28, height: 28)
                .background(Circle().fill(style.trackFill))
            VStack(alignment: .leading, spacing: 1) {
                Text(battery.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                if let status = battery.statusText {
                    Text(status).font(.system(size: 11)).monospacedDigit()
                        .foregroundStyle(battery.isLow ? Color.red : style.secondaryInk)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text("\(battery.percent)%")
                .font(.system(size: 12, weight: .semibold)).monospacedDigit()
                .foregroundStyle(battery.isLow ? Color.red : style.inkOnTrack)
            BatteryGlyph(percent: battery.percent, isCharging: battery.isCharging, isLow: battery.isLow)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(battery.name), \(battery.percent) percent\(battery.statusText.map { ", \($0)" } ?? "")")
    }

    /// An SF Symbol for the device: AirPods by model, Beats, keyboard, mouse, trackpad, controller.
    static func symbol(for battery: BatteryReading) -> String {
        let name = battery.name.lowercased()
        switch battery.kind {
        case .mac: return "laptopcomputer"
        case .headphones:
            if name.contains("airpods max") { return "airpodsmax" }
            if name.contains("airpods pro") { return "airpodspro" }
            if name.contains("airpods") { return "airpods" }
            if name.contains("beats") { return "beats.headphones" }
            return "headphones"
        case .keyboard: return "keyboard"
        case .mouse: return "magicmouse"
        case .trackpad: return "rectangle.and.hand.point.up.left"
        case .gameController: return "gamecontroller"
        case .other: return "battery.75percent"
        }
    }
}
