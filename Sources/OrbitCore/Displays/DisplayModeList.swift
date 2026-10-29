import Foundation

/// One `CGDisplayMode` as plain numbers, so the menu logic is testable without a display.
public struct RawDisplayMode: Equatable, Hashable, Sendable {
    /// `ioDisplayModeID`. Not unique on its own across refresh rates on every Mac; `DisplayModeService`
    /// matches modes on every field.
    public var id: Int32
    /// Size in points ("looks like").
    public var width: Int
    public var height: Int
    /// Backing size in pixels.
    public var pixelWidth: Int
    public var pixelHeight: Int
    /// Hz; 0 when the display doesn't say.
    public var refreshRate: Double
    /// `isUsableForDesktopGUI()`.
    public var isUsable: Bool
    /// `ioFlags` (`kDisplayModeNativeFlag` = 0x0200_0000, `kDisplayModeDefaultFlag` = 0x4).
    public var ioFlags: UInt32

    public init(id: Int32, width: Int, height: Int, pixelWidth: Int, pixelHeight: Int, refreshRate: Double,
                isUsable: Bool = true, ioFlags: UInt32 = 0x3) {
        self.id = id
        self.width = width
        self.height = height
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.refreshRate = refreshRate
        self.isUsable = isUsable
        self.ioFlags = ioFlags
    }

    public static let nativeFlag: UInt32 = 0x0200_0000
    public static let defaultFlag: UInt32 = 0x0000_0004

    /// Retina-style: the backing store is exactly twice the point size.
    public var isHiDPI: Bool { pixelWidth == width * 2 && pixelHeight == height * 2 }

    /// The panel's native resolution (macOS marks it).
    public var isNative: Bool { ioFlags & Self.nativeFlag != 0 }
}

/// One choice in a display's resolution menu.
public struct DisplayModeEntry: Equatable, Sendable, Identifiable {
    public var mode: RawDisplayMode
    /// "2560 × 1440 HiDPI".
    public var sizeLabel: String
    /// "60 Hz" when this size has several refresh rates, else nil.
    public var refreshLabel: String?
    public var isCurrent: Bool

    /// "2560 × 1440 HiDPI · 60 Hz" (the refresh only when it tells entries apart).
    public var label: String { refreshLabel.map { "\(sizeLabel) · \($0)" } ?? sizeLabel }
    public var isHiDPI: Bool { mode.isHiDPI }
    public var id: String { "\(mode.width)x\(mode.height)\(mode.isHiDPI ? "h" : "")@\(DisplayModeList.refreshKey(mode.refreshRate))" }
}

/// The entries that share one size (and HiDPI-ness): one per refresh rate, fastest first. A menu shows a
/// group with one entry as a plain item and a group with several as a submenu of rates.
public struct DisplayModeGroup: Equatable, Sendable, Identifiable {
    public var sizeLabel: String
    public var isHiDPI: Bool
    public var entries: [DisplayModeEntry]

    public var id: String { sizeLabel }
    public var isCurrent: Bool { entries.contains(where: \.isCurrent) }
}

/// A display's resolution menu, built from every mode `CGDisplayCopyAllDisplayModes` returns (with
/// `kCGDisplayShowDuplicateLowResolutionModes`): unusable modes dropped (unless current), duplicates
/// merged, sorted largest first with HiDPI before the standard mode of the same size, refresh rates
/// labelled only where a size has several, and the current mode marked.
public struct DisplayModeList: Equatable, Sendable {
    public private(set) var entries: [DisplayModeEntry]

    public init(modes: [RawDisplayMode], current: RawDisplayMode?) {
        var candidates = modes.filter { $0.isUsable || $0 == current }
        if let current, !candidates.contains(current) { candidates.insert(current, at: 0) }

        // Merge modes that would read the same in the menu, keeping the best of each.
        var best: [MenuKey: RawDisplayMode] = [:]
        var order: [MenuKey] = []
        for mode in candidates {
            let key = MenuKey(mode)
            if let kept = best[key] {
                if Self.prefer(mode, over: kept, current: current) { best[key] = mode }
            } else {
                best[key] = mode
                order.append(key)
            }
        }
        let sorted = order.compactMap { best[$0] }.sorted { a, b in
            if a.width != b.width { return a.width > b.width }
            if a.height != b.height { return a.height > b.height }
            if a.isHiDPI != b.isHiDPI { return a.isHiDPI }
            return a.refreshRate > b.refreshRate
        }

        var ratesPerSize: [SizeKey: Set<String>] = [:]
        for mode in sorted { ratesPerSize[SizeKey(mode), default: []].insert(Self.refreshKey(mode.refreshRate)) }
        entries = sorted.map { mode in
            let several = (ratesPerSize[SizeKey(mode)]?.count ?? 0) > 1
            return DisplayModeEntry(mode: mode, sizeLabel: Self.sizeLabel(mode),
                                    refreshLabel: several ? Self.refreshLabel(mode.refreshRate) : nil,
                                    isCurrent: mode == current)
        }
    }

    public static let empty = DisplayModeList(modes: [], current: nil)

    /// The current entry, if the display reported one.
    public var current: DisplayModeEntry? { entries.first(where: \.isCurrent) }

    /// The menu button's title: the current size ("3008 × 1692 HiDPI"), or "Resolution" when unknown.
    public var title: String { current?.sizeLabel ?? "Resolution" }

    /// Entries grouped by size, in menu order.
    public var groups: [DisplayModeGroup] {
        var groups: [DisplayModeGroup] = []
        for entry in entries {
            if let last = groups.last, last.sizeLabel == entry.sizeLabel {
                groups[groups.count - 1].entries.append(entry)
            } else {
                groups.append(DisplayModeGroup(sizeLabel: entry.sizeLabel, isHiDPI: entry.isHiDPI, entries: [entry]))
            }
        }
        return groups
    }

    // MARK: Helpers

    /// What makes two modes the same menu item.
    private struct MenuKey: Hashable {
        let width: Int, height: Int, hiDPI: Bool, refresh: String
        init(_ mode: RawDisplayMode) {
            width = mode.width; height = mode.height; hiDPI = mode.isHiDPI
            refresh = DisplayModeList.refreshKey(mode.refreshRate)
        }
    }

    /// What makes two modes the same size (one group).
    private struct SizeKey: Hashable {
        let width: Int, height: Int, hiDPI: Bool
        init(_ mode: RawDisplayMode) { width = mode.width; height = mode.height; hiDPI = mode.isHiDPI }
    }

    /// Of two modes that read the same: the current one, then the native-flagged one, then (for a standard
    /// entry) the one drawn 1:1, else the first seen.
    private static func prefer(_ candidate: RawDisplayMode, over kept: RawDisplayMode, current: RawDisplayMode?) -> Bool {
        if kept == current { return false }
        if candidate == current { return true }
        if candidate.isNative != kept.isNative { return candidate.isNative }
        let candidateOneToOne = candidate.pixelWidth == candidate.width && candidate.pixelHeight == candidate.height
        let keptOneToOne = kept.pixelWidth == kept.width && kept.pixelHeight == kept.height
        if !candidate.isHiDPI, candidateOneToOne != keptOneToOne { return candidateOneToOne }
        return false
    }

    static func sizeLabel(_ mode: RawDisplayMode) -> String {
        "\(mode.width) × \(mode.height)\(mode.isHiDPI ? " HiDPI" : "")"
    }

    /// "60 Hz", "59.94 Hz"; nil for 0 (unknown).
    static func refreshLabel(_ rate: Double) -> String? {
        guard rate > 0 else { return nil }
        if abs(rate - rate.rounded()) < 0.005 { return "\(Int(rate.rounded())) Hz" }
        return String(format: "%.2f Hz", rate)
    }

    static func refreshKey(_ rate: Double) -> String {
        String(format: "%.2f", rate)
    }
}
