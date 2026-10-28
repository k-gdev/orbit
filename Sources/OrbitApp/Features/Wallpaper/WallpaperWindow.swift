import AppKit
import AVFoundation
import OrbitCore

/// The borderless window one display's wallpaper plays in: at the desktop window level (below the desktop icons,
/// above the system's desktop picture), on every Space, never focused, transparent to the mouse, filling the screen.
/// Its content is a single `AVPlayerLayer` (`.resizeAspectFill`); the player is attached by `WallpaperManager`.
///
/// No black flash: until the player layer has a frame to show (`isReadyForDisplay`) the window is fully transparent,
/// so the desktop picture underneath (normally Orbit's still of the same video) shows through. That covers Orbit's
/// start, every display reconnect after wake, hot-plugging, and switching a display to another wallpaper. Once a
/// frame is ready the window turns opaque, which spares the window server blending a full-screen layer.
@MainActor
final class WallpaperWindow: NSWindow {
    let displayKey: String
    private let playerLayer = AVPlayerLayer()
    private var readiness: NSKeyValueObservation?

    /// True once macOS has reported this window visible.
    private(set) var hasBeenVisible = false
    /// When `present()` ordered the window in.
    private var shownAt: Date?
    private var loggedUnseen = false

    init(screen: NSScreen, displayKey: String) {
        self.displayKey = displayKey
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        isExcludedFromWindowsMenu = true
        title = "Orbit Wallpaper"

        let view = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.wantsLayer = true
        playerLayer.videoGravity = .resizeAspectFill
        playerLayer.frame = view.bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(playerLayer)
        contentView = view
        setFrame(screen.frame, display: false)
        showFrames(false)

        // KVO may fire on any thread; the window changes on the main thread.
        readiness = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.updateReadiness() }
            }
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Borderless windows are otherwise pushed below the menu bar; the wallpaper covers the whole screen.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// Shows `player`'s video. The window stays see-through until the new player has a frame ready.
    func attach(_ player: AVPlayer?) {
        guard playerLayer.player !== player else { return }
        showFrames(false)
        playerLayer.player = player
        updateReadiness()
    }

    /// Follows the screen after a resolution or arrangement change.
    func fit(to screen: NSScreen) {
        guard frame != screen.frame else { return }
        setFrame(screen.frame, display: true)
    }

    /// Orders the window in (it never becomes key) and starts the visibility grace period.
    func present() {
        shownAt = Date()
        orderFrontRegardless()
    }

    /// Whether the window can't be seen right now (a full-screen app or a window covers the whole display). A window
    /// macOS never reports visible plays for `WallpaperVisibility.grace` seconds, then counts as covered, so a window
    /// nobody can see (drawn under the system wallpaper, say) doesn't decode 4K video forever.
    var isCovered: Bool {
        let visible = occlusionState.contains(.visible)
        if visible { hasBeenVisible = true }
        let covered = WallpaperVisibility.isCovered(visibleNow: visible, everVisible: hasBeenVisible,
                                                    secondsSinceShown: shownAt.map { Date().timeIntervalSince($0) })
        if covered, !hasBeenVisible, !loggedUnseen {
            loggedUnseen = true
            Log.info("wallpaper: macOS never reported the window for \(displayKey) visible within \(Int(WallpaperVisibility.grace)) s; "
                     + "pausing it as covered")
        }
        return covered
    }

    /// Detaches the player and closes. The manager drops its reference afterwards.
    func tearDown() {
        readiness?.invalidate()
        readiness = nil
        playerLayer.player = nil
        orderOut(nil)
        close()
    }

    // MARK: Transparent until the first frame

    private func updateReadiness() {
        showFrames(playerLayer.player != nil && playerLayer.isReadyForDisplay)
    }

    /// `true`: opaque black behind the video. `false`: fully transparent, so the desktop picture shows through.
    private func showFrames(_ ready: Bool) {
        let fill = ready ? NSColor.black : NSColor.clear
        if isOpaque != ready { isOpaque = ready }
        backgroundColor = fill
        contentView?.layer?.backgroundColor = fill.cgColor
        playerLayer.backgroundColor = fill.cgColor
    }
}
