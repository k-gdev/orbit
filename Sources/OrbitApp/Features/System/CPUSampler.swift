import Darwin
import Foundation
import OrbitCore

/// Per-core CPU load from `host_processor_info(PROCESSOR_CPU_LOAD_INFO)`: each sample is the load since the
/// previous one. Confined to the sampling queue.
final class CPUSampler {
    private let host = mach_host_self()
    private var previous: [CPUTicks]?

    deinit { mach_port_deallocate(mach_task_self_, host) }

    /// The load since the last call, or nil on the first call after creation or `reset()` (which only
    /// records a baseline) and when the kernel call fails.
    func sample() -> CPULoad? {
        guard let current = ticks() else { return nil }
        defer { previous = current }
        guard let previous else { return nil }
        return CPULoad(previous: previous, current: current)
    }

    /// Forgets the baseline (after a gap, so the next load isn't an average over minutes).
    func reset() { previous = nil }

    private func ticks() -> [CPUTicks]? {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        let stride = Int(CPU_STATE_MAX)
        guard Int(infoCount) >= Int(cpuCount) * stride else { return nil }
        return (0..<Int(cpuCount)).map { cpu in
            let base = cpu * stride
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CPUTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                            idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }
}
