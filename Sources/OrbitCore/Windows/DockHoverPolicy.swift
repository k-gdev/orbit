import Foundation

/// When the Dock preview opens, switches and closes. The app feeds it what the Dock reports as hovered and
/// whether the pointer has left the preview, and carries out the commands it returns (the delay timer, the
/// panel). Apps are identified by pid.
public struct DockHoverPolicy: Sendable, Equatable {
    public enum Command: Sendable, Equatable {
        /// Nothing to do.
        case none
        /// Start (or restart) the hover timer; call `delayElapsed(for:)` when it fires.
        case schedule(pid: Int32, after: Double)
        /// Stop the hover timer.
        case cancelSchedule
        /// Open the preview for this app (or switch the open one to it).
        case show(pid: Int32)
        /// Close the preview.
        case hide
    }

    /// The app whose icon the pointer is resting on, waiting for the delay.
    public private(set) var pending: Int32?
    /// The app whose preview is open.
    public private(set) var shown: Int32?

    public init() {}

    /// The Dock's hovered item changed. `pid` is the app of a running app's icon, nil for anything else (the
    /// pointer left the Dock, or is over a folder, the Trash or a separator).
    ///
    /// - With nothing open, an app icon waits for `delay`; leaving it first cancels the wait.
    /// - With a preview open, another app's icon switches to it at once, and leaving the Dock keeps the
    ///   preview (the pointer may be on its way into the strip; `pointerLeft()` closes it).
    public mutating func hoverChanged(to pid: Int32?, delay: Double) -> Command {
        guard let pid else {
            guard pending != nil else { return .none }
            pending = nil
            return .cancelSchedule
        }
        if shown == pid { return .none }
        if shown != nil {
            shown = pid
            pending = nil
            return .show(pid: pid)
        }
        pending = pid
        return .schedule(pid: pid, after: delay)
    }

    /// The hover timer for `pid` fired. A stale timer (the pointer has moved on) does nothing.
    public mutating func delayElapsed(for pid: Int32) -> Command {
        guard pending == pid else { return .none }
        pending = nil
        shown = pid
        return .show(pid: pid)
    }

    /// The pointer is outside the strip, the icon and the gap between them.
    public mutating func pointerLeft() -> Command {
        guard shown != nil else { return .none }
        shown = nil
        return .hide
    }

    /// The preview closed for another reason (a window was chosen, a click elsewhere, nothing to show, the
    /// Space changed). The next hover waits for the delay again.
    public mutating func dismissed() {
        shown = nil
        pending = nil
    }
}
