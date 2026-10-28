import Foundation
import IOKit
import OrbitCore

/// Reads chip temperatures from the System Management Controller (the `AppleSMC` IOKit user client, public
/// IOKit calls, no private symbols). It only ever sends the three READ commands (key by index, key info,
/// read key), never a write. On Apple Silicon this is where the CPU ("Tp??") and GPU ("Tg??") sensors live;
/// on the M5 Max IOHID has no GPU sensors at all.
///
/// The key list is discovered once per process (about half a second: the M5 Max has ~3 700 keys) and only
/// keys `SensorGroups.classify` knows, with a temperature type, are kept. Confined to the sampling queue.
final class SMCReader {
    private var connection: io_connect_t = 0
    private var failed = false

    /// The temperature keys found by the first discovery, shared by every reader in the process.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var discovered: [Key]?

    struct Key {
        let name: String
        let code: UInt32
        let size: UInt32
        let type: String
    }

    deinit { close() }

    /// Every known temperature key's reading, or nil when the SMC can't be opened.
    func readTemperatures() -> [SensorReading]? {
        guard open() else { return nil }
        let keys = Self.cachedKeys() ?? discoverKeys()
        return keys.compactMap { key in
            guard let bytes = read(key), let celsius = SMCCode.celsius(type: key.type, bytes: bytes) else { return nil }
            return SensorReading(name: key.name, celsius: celsius)
        }
    }

    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
    }

    // MARK: Connection

    private func open() -> Bool {
        if connection != 0 { return true }
        guard !failed, MemoryLayout<KeyData>.stride == 80 else { failed = true; return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { failed = true; return false }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else {
            connection = 0
            failed = true
            Log.info("system: couldn't open the SMC; temperatures come from IOHID only")
            return false
        }
        return true
    }

    // MARK: Keys

    private static func cachedKeys() -> [Key]? {
        lock.lock(); defer { lock.unlock() }
        return discovered
    }

    private func discoverKeys() -> [Key] {
        var keys: [Key] = []
        if let count = readUInt32(SMCCode.code("#KEY")) {
            for index in 0..<count {
                guard let code = keyCode(at: index) else { continue }
                let name = SMCCode.string(code)
                guard name.hasPrefix("T"), SensorGroups.classify(name) != nil, let info = keyInfo(code) else { continue }
                let type = SMCCode.string(info.dataType)
                guard type == "flt " || type == "sp78" else { continue }
                keys.append(Key(name: name, code: code, size: info.dataSize, type: type))
            }
        }
        Self.lock.lock()
        Self.discovered = keys
        Self.lock.unlock()
        Log.info("system: \(keys.count) SMC temperature keys")
        return keys
    }

    // MARK: Commands (read only)

    private enum Command: UInt8 {
        case readKey = 5
        case keyAtIndex = 8
        case keyInfo = 9
    }

    private func read(_ key: Key) -> [UInt8]? {
        var input = KeyData()
        input.key = key.code
        input.keyInfo.dataSize = key.size
        input.data8 = Command.readKey.rawValue
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(min(key.size, 32)))) }
    }

    private func readUInt32(_ code: UInt32) -> UInt32? {
        guard let info = keyInfo(code) else { return nil }
        var input = KeyData()
        input.key = code
        input.keyInfo.dataSize = info.dataSize
        input.data8 = Command.readKey.rawValue
        guard let output = call(&input) else { return nil }
        return withUnsafeBytes(of: output.bytes) { bytes in
            bytes.prefix(Int(min(info.dataSize, 4))).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
    }

    private func keyCode(at index: UInt32) -> UInt32? {
        var input = KeyData()
        input.data8 = Command.keyAtIndex.rawValue
        input.data32 = index
        return call(&input)?.key
    }

    private func keyInfo(_ code: UInt32) -> KeyInfo? {
        var input = KeyData()
        input.key = code
        input.data8 = Command.keyInfo.rawValue
        return call(&input)?.keyInfo
    }

    private func call(_ input: inout KeyData) -> KeyData? {
        var output = KeyData()
        var outputSize = MemoryLayout<KeyData>.stride
        let result = IOConnectCallStructMethod(connection, 2, &input, MemoryLayout<KeyData>.stride, &output, &outputSize)
        return result == KERN_SUCCESS && output.result == 0 ? output : nil
    }

    // MARK: The SMC's 80-byte parameter block (SMCKeyData_t), laid out field for field as in C.

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PowerLimit {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpu: UInt32 = 0, gpu: UInt32 = 0, memory: UInt32 = 0
    }

    struct KeyInfo {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
        // C pads the struct to 12 bytes; Swift wouldn't, so the padding is spelled out.
        private var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    }

    private struct KeyData {
        var key: UInt32 = 0
        var version = Version()
        var powerLimit = PowerLimit()
        var keyInfo = KeyInfo()
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
            = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
