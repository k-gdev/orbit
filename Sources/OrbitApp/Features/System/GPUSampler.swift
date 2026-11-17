import Foundation
import IOKit

/// GPU load from the IOAccelerator service's `PerformanceStatistics` → "Device Utilization %" (public
/// IORegistry properties; no private API). The service is looked up once and kept until `close()`.
/// Confined to the sampling queue.
final class GPUSampler {
    private var service: io_service_t = 0

    deinit { close() }

    /// 0...1, or nil when no accelerator reports it.
    func sample() -> Double? {
        if service == 0 { service = findService() }
        guard service != 0 else { return nil }
        if let value = utilization(of: service) { return value }
        // The accelerator went away (driver restart): look again next time.
        close()
        return nil
    }

    func close() {
        if service != 0 { IOObjectRelease(service) }
        service = 0
    }

    /// The GPU's core count (`gpu-core-count`, 40 on an M5 Max), or nil when no accelerator says.
    static func coreCount() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            if let count = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? NSNumber {
                return count.intValue
            }
        }
        return nil
    }

    /// The first IOAccelerator whose statistics carry "Device Utilization %".
    private func findService() -> io_service_t {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        while case let candidate = IOIteratorNext(iterator), candidate != 0 {
            if utilization(of: candidate) != nil { return candidate }
            IOObjectRelease(candidate)
        }
        return 0
    }

    private func utilization(of service: io_service_t) -> Double? {
        guard let stats = IORegistryEntryCreateCFProperty(service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any],
              let percent = stats["Device Utilization %"] as? NSNumber else { return nil }
        return min(max(percent.doubleValue / 100, 0), 1)
    }
}
