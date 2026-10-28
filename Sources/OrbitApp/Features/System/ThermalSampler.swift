import Foundation
import IOKit
import OrbitCore

/// Chip temperatures from two read-only sources, merged and grouped by `SensorGroups`:
/// - IOHID temperature services (private `IOHIDEventSystemClient*` functions through `PrivateSymbol`,
///   matching PrimaryUsagePage 0xff00 / PrimaryUsage 5, event type 15 → temperature). On the M5 Max these
///   are the SoC die sensors ("PMU tdie*").
/// - The SMC (`SMCReader`): the CPU ("Tp??") and GPU ("Tg??") sensors.
/// Either source may be missing (a symbol not found, the SMC refusing); the other still reports. Nothing is
/// opened until the first sample; `close()` releases both. Confined to the sampling queue.
final class ThermalSampler {
    private typealias ClientCreate = @convention(c) (CFAllocator?) -> Unmanaged<CFTypeRef>?
    private typealias ClientSetMatching = @convention(c) (CFTypeRef, CFDictionary) -> Int32
    private typealias ClientCopyServices = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private typealias ServiceCopyProperty = @convention(c) (CFTypeRef, CFString) -> Unmanaged<CFTypeRef>?
    private typealias ServiceCopyEvent = @convention(c) (CFTypeRef, Int64, Int32, Int64) -> Unmanaged<CFTypeRef>?
    private typealias EventGetFloat = @convention(c) (CFTypeRef, Int32) -> Double

    private struct HID {
        let copyEvent: ServiceCopyEvent
        let getFloat: EventGetFloat
        let client: CFTypeRef
        /// The temperature services `SensorGroups` knows, with their names.
        let services: [(name: String, service: CFTypeRef)]
    }

    private static let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"
    private static let temperatureEvent: Int64 = 15                 // kIOHIDEventTypeTemperature
    private static let temperatureField = Int32(15 << 16)           // kIOHIDEventFieldTemperatureLevel

    private var hid: HID?
    private var hidUnavailable = false
    private let smc = SMCReader()

    deinit { close() }

    /// Grouped temperatures, or nil when neither source gave a reading.
    func sample() -> SensorGroups? {
        var readings = smc.readTemperatures() ?? []
        readings += hidReadings()
        let groups = SensorGroups(readings: readings)
        return groups.isEmpty ? nil : groups
    }

    func close() {
        hid = nil       // releases the client and services
        smc.close()
    }

    // MARK: IOHID

    private func hidReadings() -> [SensorReading] {
        guard let hid = hid ?? openHID() else { return [] }
        return hid.services.compactMap { entry in
            guard let event = hid.copyEvent(entry.service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { return nil }
            return SensorReading(name: entry.name, celsius: hid.getFloat(event, Self.temperatureField))
        }
    }

    private func openHID() -> HID? {
        guard !hidUnavailable else { return nil }
        guard let create = PrivateSymbol.load("IOHIDEventSystemClientCreate", from: Self.iokit, as: ClientCreate.self),
              let setMatching = PrivateSymbol.load("IOHIDEventSystemClientSetMatching", from: Self.iokit, as: ClientSetMatching.self),
              let copyServices = PrivateSymbol.load("IOHIDEventSystemClientCopyServices", from: Self.iokit, as: ClientCopyServices.self),
              let copyProperty = PrivateSymbol.load("IOHIDServiceClientCopyProperty", from: Self.iokit, as: ServiceCopyProperty.self),
              let copyEvent = PrivateSymbol.load("IOHIDServiceClientCopyEvent", from: Self.iokit, as: ServiceCopyEvent.self),
              let getFloat = PrivateSymbol.load("IOHIDEventGetFloatValue", from: Self.iokit, as: EventGetFloat.self),
              let client = create(kCFAllocatorDefault)?.takeRetainedValue() else {
            hidUnavailable = true
            return nil
        }
        _ = setMatching(client, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
        let all = (copyServices(client)?.takeRetainedValue() as? [CFTypeRef]) ?? []
        let services: [(name: String, service: CFTypeRef)] = all.compactMap { service in
            guard let name = copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  SensorGroups.classify(name) != nil else { return nil }
            return (name, service)
        }
        guard !services.isEmpty else {
            hidUnavailable = true
            return nil
        }
        let opened = HID(copyEvent: copyEvent, getFloat: getFloat, client: client, services: services)
        hid = opened
        return opened
    }
}
