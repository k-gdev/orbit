import AppKit
import CoreAudio
import Darwin
import OrbitCore

/// One process that is a Core Audio client (`kAudioHardwarePropertyProcessObjectList`).
struct AudioProcess: Equatable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String?
    /// The app whose pill this process belongs under (`AudioAppGrouping`).
    let appBundleID: String?
    var isRunningOutput: Bool
    /// The UIDs of the output devices the process is playing to (`kAudioProcessPropertyDevices`).
    var outputDeviceUIDs: [String]
}

/// The audio processes on the system, grouped by app. Reading is on demand (`refresh()`); listening for
/// changes (the process list, and each process's "is playing" flag and output devices) happens only
/// between `startListening()` and `stopListening()`, which `SoundEngine` brackets around the times it
/// matters: the panel is open, a tap exists, or an app has settings waiting for it to start.
///
/// Read-only: nothing here changes any process or device.
@available(macOS 14.2, *)
@MainActor
final class AudioProcessMonitor {
    private(set) var processes: [AudioProcess] = []
    /// Called (on the main thread) after the list, a playing flag or a process's devices changed while
    /// listening.
    var onChange: (() -> Void)?

    private var listListener: SoundHALListener?
    private var processListeners: [AudioObjectID: [SoundHALListener]] = [:]
    private var groupCache: [pid_t: (bundleID: String?, app: String?)] = [:]
    private let ownPID = getpid()

    var isListening: Bool { listListener != nil }

    func startListening() {
        guard listListener == nil else { return }
        listListener = SoundHALListener(object: SoundHAL.system, SoundHAL.address(kAudioHardwarePropertyProcessObjectList)) { [weak self] in
            self?.refresh()
            self?.onChange?()
        }
        refresh()
    }

    func stopListening() {
        listListener?.remove()
        listListener = nil
        processListeners.values.joined().forEach { $0.remove() }
        processListeners = [:]
    }

    /// Re-reads the process list (and, while listening, keeps listeners on each process).
    func refresh() {
        let objects = SoundHAL.objects(SoundHAL.system, SoundHAL.address(kAudioHardwarePropertyProcessObjectList))
        var next: [AudioProcess] = []
        var livePIDs = Set<pid_t>()
        for object in objects {
            guard let pid = SoundHAL.read(object, SoundHAL.address(kAudioProcessPropertyPID), zero: pid_t(0)),
                  pid > 0, pid != ownPID else { continue }
            livePIDs.insert(pid)
            let group = grouping(for: object, pid: pid)
            next.append(AudioProcess(objectID: object, pid: pid, bundleID: group.bundleID, appBundleID: group.app,
                                     isRunningOutput: Self.isPlaying(object), outputDeviceUIDs: Self.outputDevices(object)))
        }
        groupCache = groupCache.filter { livePIDs.contains($0.key) }
        if next != processes { processes = next }
        if isListening { syncProcessListeners() }
    }

    /// The process objects of one app (all of them, playing or not, so a tap covers sounds that start later).
    func processObjects(forApp bundleID: String) -> [AudioObjectID] {
        processes.filter { $0.appBundleID == bundleID }.map(\.objectID).sorted()
    }

    /// The output devices an app's processes are playing to (duplicates included).
    func outputDeviceUIDs(forApp bundleID: String) -> [String] {
        processes.filter { $0.appBundleID == bundleID }.flatMap(\.outputDeviceUIDs)
    }

    /// Per app: whether any of its processes is playing, and a PID to resolve its name and icon from.
    func apps() -> [String: (isPlaying: Bool, pids: [pid_t])] {
        var result: [String: (isPlaying: Bool, pids: [pid_t])] = [:]
        for process in processes {
            guard let app = process.appBundleID else { continue }
            var entry = result[app] ?? (false, [])
            entry.isPlaying = entry.isPlaying || process.isRunningOutput
            entry.pids.append(process.pid)
            result[app] = entry
        }
        return result
    }

    private func syncProcessListeners() {
        let live = Set(processes.map(\.objectID))
        for (object, listeners) in processListeners where !live.contains(object) {
            listeners.forEach { $0.remove() }
            processListeners[object] = nil
        }
        for object in live where processListeners[object] == nil {
            let changed: @MainActor () -> Void = { [weak self] in self?.processChanged(object) }
            processListeners[object] = [
                SoundHALListener(object: object, SoundHAL.address(kAudioProcessPropertyIsRunningOutput), action: changed),
                SoundHALListener(object: object, SoundHAL.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput), action: changed),
            ].compactMap { $0 }
        }
    }

    private func processChanged(_ object: AudioObjectID) {
        guard let index = processes.firstIndex(where: { $0.objectID == object }) else { return }
        let playing = Self.isPlaying(object), devices = Self.outputDevices(object)
        guard processes[index].isRunningOutput != playing || processes[index].outputDeviceUIDs != devices else { return }
        processes[index].isRunningOutput = playing
        processes[index].outputDeviceUIDs = devices
        onChange?()
    }

    private static func isPlaying(_ object: AudioObjectID) -> Bool {
        (SoundHAL.read(object, SoundHAL.address(kAudioProcessPropertyIsRunningOutput), zero: UInt32(0)) ?? 0) != 0
    }

    private static func outputDevices(_ object: AudioObjectID) -> [String] {
        SoundHAL.objects(object, SoundHAL.address(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput))
            .compactMap(SoundHAL.uid(of:))
            .filter { !$0.hasPrefix(SoundHAL.aggregateUIDPrefix) }
    }

    // MARK: Grouping

    private func grouping(for object: AudioObjectID, pid: pid_t) -> (bundleID: String?, app: String?) {
        if let cached = groupCache[pid] { return cached }
        let own = SoundHAL.string(object, SoundHAL.address(kAudioProcessPropertyBundleID)).flatMap { $0.isEmpty ? nil : $0 }
        let running = NSRunningApplication(processIdentifier: pid)
        let isApp = running?.activationPolicy == .regular
        var responsible: String?
        if !isApp, let rpid = Self.responsiblePID(for: pid), rpid > 0, rpid != pid {
            responsible = NSRunningApplication(processIdentifier: rpid)?.bundleIdentifier
        }
        let app = AudioAppGrouping.appBundleID(processBundleID: own ?? running?.bundleIdentifier,
                                               responsibleBundleID: responsible, processIsApp: isApp)
        let result = (own, app)
        groupCache[pid] = result
        return result
    }

    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// The PID macOS holds responsible for `pid` (Chrome for its helpers, Safari for WebKit's GPU
    /// process), through the private `responsibility_get_pid_responsible_for_pid`. Nil when the symbol is
    /// missing.
    private static func responsiblePID(for pid: pid_t) -> pid_t? {
        guard let fn = PrivateSymbol.load("responsibility_get_pid_responsible_for_pid", from: "/usr/lib/libSystem.B.dylib",
                                          as: ResponsibleFn.self) else { return nil }
        return fn(pid)
    }
}
