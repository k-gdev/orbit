import Foundation

/// Maps an audio process to the app it belongs to, so each app gets one pill in the mixer however many
/// processes it plays from (Chrome's audio comes from `com.google.Chrome.helper`, Safari's from
/// `com.apple.WebKit.GPU`, Discord's from `com.hnc.Discord.helper.Renderer`).
public enum AudioAppGrouping {
    /// The bundle ID of the app whose pill a process belongs under.
    ///
    /// - Parameters:
    ///   - processBundleID: the process's own bundle ID (`kAudioProcessPropertyBundleID`), if any.
    ///   - responsibleBundleID: the bundle ID of the app macOS holds responsible for the process (its
    ///     "responsible PID"), when the caller could find one.
    ///   - processIsApp: the process is itself a user-facing app (it keeps its own pill even when another
    ///     app launched it, e.g. a game started from Xcode).
    public static func appBundleID(processBundleID: String?, responsibleBundleID: String? = nil,
                                   processIsApp: Bool = false) -> String? {
        let own = processBundleID.flatMap { $0.isEmpty ? nil : $0 }
        let responsible = responsibleBundleID.flatMap { $0.isEmpty ? nil : $0 }
        if processIsApp, let own { return own }
        if let responsible, responsible != own { return responsible }
        if let own, let parent = helperParent(of: own) { return parent }
        return own
    }

    /// For a helper's bundle ID, the app's: everything before a `helper` (or `…-helper`) component that
    /// comes after at least two components (`com.google.Chrome.helper.renderer` → `com.google.Chrome`).
    /// Nil when the ID has no such component.
    public static func helperParent(of bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".", omittingEmptySubsequences: false)
        guard let index = parts.indices.first(where: { i in
            guard i >= 2 else { return false }
            let part = parts[i].lowercased()
            return part == "helper" || part.hasSuffix("-helper")
        }) else { return nil }
        return parts[..<index].joined(separator: ".")
    }
}

/// One app that could appear in the mixer's Apps list.
public struct AudioAppCandidate: Equatable, Sendable {
    public var bundleID: String
    public var name: String
    /// At least one of its processes is an audio client right now.
    public var isRunning: Bool
    /// At least one of its processes is playing (`kAudioProcessPropertyIsRunningOutput`).
    public var isPlaying: Bool
    /// A user-facing app (Dock or menu bar app), not a system daemon.
    public var isListable: Bool

    public init(bundleID: String, name: String, isRunning: Bool, isPlaying: Bool, isListable: Bool) {
        self.bundleID = bundleID
        self.name = name
        self.isRunning = isRunning
        self.isPlaying = isPlaying
        self.isListable = isListable
    }
}

/// Which apps the Apps list shows, in what order.
public enum AudioAppList {
    /// Shown: pinned apps (running or not, as long as the caller supplied them) and every user-facing app
    /// that is playing, or running with settings of its own (`customised`), or running at all when
    /// `showAll` is on. Ordered as in the mockup: playing apps by name, then quiet pinned apps in pinned
    /// order, then the rest by name. Duplicate entries for one bundle ID merge; `excluding` (Orbit itself)
    /// never shows.
    public static func visible(_ candidates: [AudioAppCandidate], pinned: [String], customised: Set<String>,
                               showAll: Bool, excluding: Set<String> = []) -> [AudioAppCandidate] {
        var merged: [String: AudioAppCandidate] = [:]
        var order: [String] = []
        for candidate in candidates where !excluding.contains(candidate.bundleID) {
            if var existing = merged[candidate.bundleID] {
                existing.isRunning = existing.isRunning || candidate.isRunning
                existing.isPlaying = existing.isPlaying || candidate.isPlaying
                existing.isListable = existing.isListable || candidate.isListable
                if existing.name.isEmpty { existing.name = candidate.name }
                merged[candidate.bundleID] = existing
            } else {
                merged[candidate.bundleID] = candidate
                order.append(candidate.bundleID)
            }
        }
        let pinnedSet = Set(pinned)
        func byName(_ a: AudioAppCandidate, _ b: AudioAppCandidate) -> Bool {
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? a.bundleID < b.bundleID : order == .orderedAscending
        }
        let shown = order.compactMap { merged[$0] }.filter { app in
            if pinnedSet.contains(app.bundleID) { return true }
            guard app.isListable else { return false }
            return app.isPlaying || (app.isRunning && (showAll || customised.contains(app.bundleID)))
        }
        let playing = shown.filter(\.isPlaying).sorted(by: byName)
        var seenPinned = Set<String>()
        let quietPinned = pinned.compactMap { id -> AudioAppCandidate? in
            guard seenPinned.insert(id).inserted, let app = merged[id], !app.isPlaying else { return nil }
            return app
        }
        let rest = shown.filter { !$0.isPlaying && !pinnedSet.contains($0.bundleID) }.sorted(by: byName)
        return playing + quietPinned + rest
    }
}
