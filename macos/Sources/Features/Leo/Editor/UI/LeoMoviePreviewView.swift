import AVKit

/// A previewed movie (B-278): native AVKit inline controls, never
/// autoplayed, paused whenever it leaves the screen (its tab hidden, its
/// pane closed). `stop()` lets go of the file before its folder goes.
///
/// The player view is laid out by frame, outside Auto Layout: AVKit's
/// inline controls bar asks to be 750 pt wide at priority 499, above the
/// split's holding priorities, so as a constrained subview it widened the
/// editor pane and squeezed the terminal beside it to ~40 pt.
final class LeoMoviePreviewView: NSView {
    private let playerView = LeoMoviePlayerView()

    var player: AVPlayer? { playerView.player }

    /// What takes focus: the player, for its space-to-play keys.
    var focusTarget: NSView { playerView }

    init(url: URL, name: String) {
        super.init(frame: .zero)
        playerView.controlsStyle = .inline
        playerView.showsFullScreenToggleButton = true
        playerView.player = AVPlayer(url: url)
        // No mask: the generated constraints pin a fixed frame, which
        // `layout()` keeps equal to the bounds, never this view's width.
        playerView.translatesAutoresizingMaskIntoConstraints = true
        playerView.autoresizingMask = []
        addSubview(playerView)
        setAccessibilityElement(false)
        playerView.setAccessibilityLabel(name)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        playerView.frame = bounds
    }

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

private final class LeoMoviePlayerView: AVPlayerView {
    override var acceptsFirstResponder: Bool { true }
}
