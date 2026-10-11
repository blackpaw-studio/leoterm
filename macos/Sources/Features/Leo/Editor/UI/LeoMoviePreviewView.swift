import AVKit

/// A previewed movie (B-278): native AVKit inline controls, never
/// autoplayed, paused whenever it leaves the screen (its tab hidden, its
/// pane closed). `stop()` lets go of the file before its folder goes.
final class LeoMoviePreviewView: AVPlayerView {
    init(url: URL, name: String) {
        super.init(frame: .zero)
        controlsStyle = .inline
        showsFullScreenToggleButton = true
        player = AVPlayer(url: url)
        setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    func stop() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { player?.pause() }
    }

    override func viewDidHide() {
        super.viewDidHide()
        player?.pause()
    }
}
