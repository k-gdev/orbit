import Darwin
import Foundation
import OrbitCore

/// The only way Orbit reaches private API (DisplayServices, IOAVService DDC, IOHIDEventSystem sensors,
/// TCC): `dlopen` the framework, `dlsym` the function, and cast it to a `@convention(c)` type. A missing
/// framework or symbol returns nil (and logs once), so callers degrade instead of crashing:
///
///     typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
///     if let get = PrivateSymbol.load("DisplayServicesGetBrightness",
///                                     from: "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
///                                     as: GetBrightness.self) { ... }
///
/// `T` must be a C function pointer type (pointer-sized); anything else returns nil. Handles are opened
/// with `RTLD_LAZY` and cached for the life of the process. Thread-safe.
enum PrivateSymbol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handles: [String: UnsafeMutableRawPointer] = [:]
    nonisolated(unsafe) private static var logged: Set<String> = []

    static func load<T>(_ name: String, from path: String, as type: T.Type) -> T? {
        guard MemoryLayout<T>.size == MemoryLayout<UnsafeRawPointer>.size else {
            logOnce("\(path)#\(name)", "PrivateSymbol: \(T.self) is not a C function pointer type")
            return nil
        }
        guard let handle = handle(for: path) else { return nil }
        guard let symbol = dlsym(handle, name) else {
            logOnce("\(path)#\(name)", "PrivateSymbol: \(name) not found in \(path)")
            return nil
        }
        return unsafeBitCast(symbol, to: T.self)
    }

    /// Whether `name` exists in the framework at `path` (for showing a feature as unavailable up front).
    static func exists(_ name: String, in path: String) -> Bool {
        guard let handle = handle(for: path) else { return false }
        return dlsym(handle, name) != nil
    }

    private static func handle(for path: String) -> UnsafeMutableRawPointer? {
        lock.lock()
        if let cached = handles[path] { lock.unlock(); return cached }
        lock.unlock()
        guard let opened = dlopen(path, RTLD_LAZY) else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown error"
            logOnce(path, "PrivateSymbol: couldn't open \(path): \(reason)")
            return nil
        }
        lock.lock(); defer { lock.unlock() }
        if let raced = handles[path] { dlclose(opened); return raced }
        handles[path] = opened
        return opened
    }

    private static func logOnce(_ key: String, _ message: String) {
        lock.lock()
        let first = logged.insert(key).inserted
        lock.unlock()
        if first { Log.info(message) }
    }
}
