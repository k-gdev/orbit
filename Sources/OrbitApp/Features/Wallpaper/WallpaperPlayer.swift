import AVFoundation

/// One looping, muted video. Displays showing the same wallpaper share one player (one decoder), each through its
/// own window's `AVPlayerLayer`.
@MainActor
final class WallpaperPlayer {
    let url: URL
    let player: AVQueuePlayer
    private var looper: AVPlayerLooper?
    private(set) var isPlaying = false

    init(url: URL) {
        self.url = url
        player = AVQueuePlayer()
        player.isMuted = true
        player.volume = 0
        player.preventsDisplaySleepDuringVideoPlayback = false
        player.allowsExternalPlayback = false
        player.automaticallyWaitsToMinimizeStalling = false
        let item = AVPlayerItem(asset: AVURLAsset(url: url))
        looper = AVPlayerLooper(player: player, templateItem: item)
    }

    /// Plays or pauses; repeated calls with the same value do nothing.
    func setPlaying(_ on: Bool) {
        guard on != isPlaying else { return }
        isPlaying = on
        if on { player.play() } else { player.pause() }
    }

    /// Stops for good and lets go of the decoder.
    func invalidate() {
        player.pause()
        isPlaying = false
        looper?.disableLooping()
        looper = nil
        player.removeAllItems()
    }
}
