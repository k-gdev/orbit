import CoreGraphics
import Foundation
import IOKit
import OrbitCore

/// DDC/CI brightness for external monitors on Apple Silicon, over the private `IOAVService` I2C calls in
/// IOKit (reached only via `PrivateSymbol`). Intel Macs have no `DCPAVServiceProxy`; there `isSupported` is
/// false and displays fall back to software dimming.
///
/// All I/O runs on one serial queue, so commands to the monitors never overlap:
/// - `probe` walks the IORegistry for external `DCPAVServiceProxy` entries (with their framebuffers), matches
///   them to displays with `DDCServiceMatcher`, keeps an `IOAVService` per matched display, and reads VCP 0x10
///   from each requested display: write the Get VCP request (twice, 10 ms apart), wait 50 ms, read the 11-byte
///   reply, accept it only if `DDC.parseVCPReply` does; up to three attempts.
/// - `write` keeps only the latest value per display (a drag produces many); the queue sends it, then waits
///   50 ms before the next message as DDC/CI asks.
/// - A matched service that stops answering (a failed read, or a write the driver refuses) is logged and the
///   next probe walks the registry again: after sleep the DCP may have rebuilt its services. A refused write
///   also drops that endpoint and calls `onWriteFailure`, so the model re-probes the display.
final class DDCService: @unchecked Sendable {
    static let iokit = "/System/Library/Frameworks/IOKit.framework/IOKit"

    private typealias CreateWithService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias I2CTransfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    /// Whether this Mac does DDC this way: Apple Silicon, with the IOAVService symbols present.
    static var isSupported: Bool {
        #if arch(arm64)
        return ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C"].allSatisfy {
            PrivateSymbol.exists($0, in: iokit)
        }
        #else
        return false
        #endif
    }

    private let queue = DispatchQueue(label: "app.orbit.displays.ddc", qos: .userInitiated)
    private let lock = NSLock()
    private var failureHandler: (@MainActor (CGDirectDisplayID) -> Void)?

    /// Runs on the main actor when a DDC write to a display was refused (its endpoint has been dropped).
    var onWriteFailure: (@MainActor (CGDirectDisplayID) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return failureHandler }
        set { lock.lock(); failureHandler = newValue; lock.unlock() }
    }

    // Queue-only state.
    private var endpoints: [CGDirectDisplayID: Endpoint] = [:]
    private var needsScan = true
    private var pendingWrites: [CGDirectDisplayID: Int] = [:]

    private final class Endpoint {
        let service: io_service_t
        let av: CFTypeRef

        init(service: io_service_t, av: CFTypeRef) {
            self.service = service
            self.av = av
        }

        deinit { IOObjectRelease(service) }
    }

    /// One display taking part in matching; `read` asks for its current brightness too.
    struct Target {
        let id: CGDirectDisplayID
        let descriptor: DisplayDescriptor
        let read: Bool
    }

    /// Matches services to `targets` (walking the registry again when `rescan`, after a failure, or when
    /// nothing is cached), then reads VCP 0x10 from each target marked `read`. `result` runs on the main actor
    /// once per such target: nil when the display has no DDC endpoint or didn't give a valid reply.
    func probe(_ targets: [Target], rescan: Bool, result: @escaping @MainActor (CGDirectDisplayID, VCPValue?) -> Void) {
        guard Self.isSupported else {
            DispatchQueue.main.async { MainActor.assumeIsolated { for target in targets where target.read { result(target.id, nil) } } }
            return
        }
        queue.async { [self] in
            if rescan || needsScan { connect(targets) }
            for target in targets where target.read {
                var value: VCPValue?
                if let endpoint = endpoints[target.id] {
                    value = readVCP(endpoint.av, code: DDC.brightness)
                    if value == nil {
                        Log.info("displays: no valid DDC reply from display \(target.id) after 3 attempts; will re-scan its service")
                        needsScan = true
                    }
                }
                DispatchQueue.main.async { MainActor.assumeIsolated { result(target.id, value) } }
            }
        }
    }

    /// Queues `value` for VCP 0x10 on `id`; a newer value for the same display replaces one not sent yet.
    func write(_ value: Int, to id: CGDirectDisplayID) {
        guard Self.isSupported else { return }
        queue.async { [self] in
            let alreadyQueued = pendingWrites[id] != nil
            pendingWrites[id] = value
            if !alreadyQueued { queue.async { [self] in flushWrite(id) } }
        }
    }

    /// Drops queued writes and every matched service, so nothing goes to a stale pairing and the next probe
    /// walks the registry again (display changes, wake, stop).
    func invalidate() {
        queue.async { [self] in
            pendingWrites.removeAll()
            endpoints.removeAll()
            needsScan = true
        }
    }

    // MARK: Queue work

    private func connect(_ targets: [Target]) {
        endpoints.removeAll()
        needsScan = false
        guard let create = PrivateSymbol.load("IOAVServiceCreateWithService", from: Self.iokit, as: CreateWithService.self) else { return }
        let found = Self.scanRegistry()
        let match = DDCServiceMatcher.match(services: found.map(\.descriptor), displays: targets.map(\.descriptor))
        for (serviceIndex, service) in found.enumerated() {
            guard let displayIndex = match[serviceIndex] else {
                IOObjectRelease(service.object)
                continue
            }
            guard let av = create(kCFAllocatorDefault, service.object)?.takeRetainedValue() else {
                Log.info("displays: IOAVServiceCreateWithService failed for \(service.descriptor.productName ?? "a display")")
                IOObjectRelease(service.object)
                continue
            }
            endpoints[targets[displayIndex].id] = Endpoint(service: service.object, av: av)
        }
        Log.info("displays: DDC endpoints for \(endpoints.count) of \(found.count) external AV services")
    }

    private func readVCP(_ av: CFTypeRef, code: UInt8) -> VCPValue? {
        guard let write = PrivateSymbol.load("IOAVServiceWriteI2C", from: Self.iokit, as: I2CTransfer.self),
              let read = PrivateSymbol.load("IOAVServiceReadI2C", from: Self.iokit, as: I2CTransfer.self) else { return nil }
        let request = DDC.getVCPRequest(code: code)
        let address = UInt32(request[0])
        for _ in 0..<3 {
            var payload = Array(request.dropFirst())
            var sent = false
            for _ in 0..<2 {
                usleep(10_000)
                let status = payload.withUnsafeMutableBytes { write(av, UInt32(DDC.chipAddress), address, $0.baseAddress!, UInt32($0.count)) }
                if status == kIOReturnSuccess { sent = true }
            }
            if sent {
                usleep(50_000)
                var reply = [UInt8](repeating: 0, count: DDC.replyLength)
                let status = reply.withUnsafeMutableBytes { read(av, UInt32(DDC.chipAddress), address, $0.baseAddress!, UInt32($0.count)) }
                if status == kIOReturnSuccess, let value = DDC.parseVCPReply(reply, code: code) { return value }
            }
            usleep(20_000)
        }
        return nil
    }

    private func flushWrite(_ id: CGDirectDisplayID) {
        guard let value = pendingWrites.removeValue(forKey: id), let endpoint = endpoints[id],
              let write = PrivateSymbol.load("IOAVServiceWriteI2C", from: Self.iokit, as: I2CTransfer.self) else { return }
        let request = DDC.setVCPRequest(code: DDC.brightness, value: value)
        var payload = Array(request.dropFirst())
        var statuses: [IOReturn] = []
        for _ in 0..<2 {
            usleep(10_000)
            statuses.append(payload.withUnsafeMutableBytes {
                write(endpoint.av, UInt32(DDC.chipAddress), UInt32(request[0]), $0.baseAddress!, UInt32($0.count))
            })
        }
        usleep(50_000)
        guard !statuses.contains(kIOReturnSuccess) else { return }
        let codes = statuses.map { String(format: "0x%08X", UInt32(bitPattern: $0)) }.joined(separator: ", ")
        Log.info("displays: DDC write of \(value) to display \(id) failed (\(codes)); dropping its service and re-scanning")
        endpoints[id] = nil
        needsScan = true
        let handler = onWriteFailure
        DispatchQueue.main.async { MainActor.assumeIsolated { handler?(id) } }
    }

    // MARK: IORegistry

    private struct FoundService {
        let descriptor: AVServiceDescriptor
        let object: io_service_t
    }

    /// Every external `DCPAVServiceProxy` (retained; the caller releases) with its framebuffer's facts.
    private static func scanRegistry() -> [FoundService] {
        var entries: [AVServicePairing.Entry] = []
        var properties: [Int: [String: Any]] = [:]
        var objects: [Int: io_service_t] = [:]
        var iterator: io_iterator_t = 0
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { if root != 0 { IOObjectRelease(root) } }
        guard root != 0,
              IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            let className = Self.className(of: entry)
            if className == "IOMobileFramebufferShim" || className == "AppleCLCD2" {
                var facts: [String: Any] = [:]
                for key in ["EDID UUID", "DisplayAttributes"] { facts[key] = property(entry, key) }
                properties[entries.count] = facts
                entries.append(.init(.framebuffer, path: path(of: entry)))
                IOObjectRelease(entry)
            } else if className == "DCPAVServiceProxy" {
                let external = (property(entry, "Location") as? String) == "External"
                if external { objects[entries.count] = entry } else { IOObjectRelease(entry) }
                entries.append(.init(.service(external: external), path: path(of: entry)))
            } else {
                IOObjectRelease(entry)
            }
            entry = IOIteratorNext(iterator)
        }
        let pairs = AVServicePairing.pair(entries)
        return objects.keys.sorted().map { index in
            let framebuffer = pairs[index]
            let descriptor = AVServiceDescriptor(framebufferPath: framebuffer.map { entries[$0].path },
                                                 properties: framebuffer.flatMap { properties[$0] } ?? [:])
            return FoundService(descriptor: descriptor, object: objects[index]!)
        }
    }

    private static func className(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 128)
        IOObjectGetClass(entry, &buffer)
        return String(cString: buffer)
    }

    private static func path(of entry: io_registry_entry_t) -> String {
        var buffer = [CChar](repeating: 0, count: 512)
        guard IORegistryEntryGetPath(entry, kIOServicePlane, &buffer) == KERN_SUCCESS else { return "" }
        return String(cString: buffer)
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }
}
