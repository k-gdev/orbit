import Darwin
import Foundation
import OrbitCore

/// Memory use from `host_statistics64(HOST_VM_INFO64)`, `hw.memsize` and
/// `kern.memorystatus_vm_pressure_level`. Confined to the sampling queue.
final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let total = ProcessInfo.processInfo.physicalMemory

    init() {
        var size: vm_size_t = 0
        pageSize = host_page_size(host, &size) == KERN_SUCCESS && size > 0 ? UInt64(size) : UInt64(getpagesize())
    }

    deinit { mach_port_deallocate(mach_task_self_, host) }

    func sample() -> MemoryStats? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        return MemoryStats(pageSize: pageSize, free: UInt64(stats.free_count), active: UInt64(stats.active_count),
                           inactive: UInt64(stats.inactive_count), wired: UInt64(stats.wire_count),
                           compressed: UInt64(stats.compressor_page_count), totalBytes: total,
                           pressure: MemoryPressure(kernelLevel: SystemInfo.int("kern.memorystatus_vm_pressure_level") ?? 1))
    }
}
