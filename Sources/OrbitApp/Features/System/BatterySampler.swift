import Foundation
import IOKit
import IOKit.ps
import OrbitCore

/// The Mac's battery and connected devices' batteries, read-only:
/// - IOPowerSources. The public list has only the internal battery; Bluetooth accessories (AirPods with
///   each bud and the case, keyboards, mice) come from `IOPSCopyPowerSourcesByType(kIOPSSourceAll = 0)`
///   (private, through `PrivateSymbol`; on Kevo's Mac it lists AirPods and an MX Keys S). Without the
///   symbol only the public list is read.
/// - IORegistry HID services that publish `BatteryPercent` (`AppleDeviceManagementHIDEventService`: Magic
///   Mouse / Keyboard / Trackpad).
/// Confined to the sampling queue.
final class BatterySampler {
    private typealias CopyByType = @convention(c) (Int32) -> Unmanaged<CFTypeRef>?

    private static let allSources: Int32 = 0       // kIOPSSourceAll
    private let copyByType = PrivateSymbol.load("IOPSCopyPowerSourcesByType",
                                                from: "/System/Library/Frameworks/IOKit.framework/IOKit", as: CopyByType.self)

    func sample() -> [BatteryReading] {
        BatteryParser.readings(powerSources: powerSourceDescriptions(), registry: registryDevices())
    }

    private func powerSourceDescriptions() -> [[String: Any]] {
        let blob = copyByType?(Self.allSources)?.takeRetainedValue() ?? IOPSCopyPowerSourcesInfo()?.takeRetainedValue()
        guard let blob, let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] else { return [] }
        return list.compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
    }

    private func registryDevices() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var devices: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var properties: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dictionary = properties?.takeRetainedValue() as? [String: Any],
                  dictionary["BatteryPercent"] != nil else { continue }
            devices.append(dictionary)
        }
        return devices
    }
}
