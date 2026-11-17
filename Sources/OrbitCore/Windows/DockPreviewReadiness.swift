import Foundation

/// Whether the Dock preview can run, and how well. Decides whether Orbit watches the Dock at all (never
/// with the Windows feature off, never without Accessibility, never with the preview turned off) and what
/// the Settings page says.
public enum DockPreviewReadiness: Sendable, Equatable, CaseIterable {
    /// The Windows feature itself is off (Settings → Features).
    case featureOff
    /// "Dock preview" is off in the Windows settings.
    case off
    /// Accessibility is missing: Orbit can't see which Dock icon is hovered, so nothing runs.
    case needsAccessibility
    /// Accessibility only: the preview shows title cards instead of thumbnails (no Screen Recording).
    case titlesOnly
    /// Everything granted: thumbnails.
    case ready

    public init(featureOn: Bool = true, enabled: Bool, accessibility: Bool, screenRecording: Bool) {
        if !featureOn { self = .featureOff }
        else if !enabled { self = .off }
        else if !accessibility { self = .needsAccessibility }
        else if !screenRecording { self = .titlesOnly }
        else { self = .ready }
    }

    /// Whether the Dock observer runs in this state.
    public var watchesDock: Bool {
        switch self {
        case .titlesOnly, .ready: true
        case .featureOff, .off, .needsAccessibility: false
        }
    }
}
