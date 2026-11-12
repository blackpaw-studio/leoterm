import AppKit
import Combine
import LeoKit

/// The Terminal tab's body for one agent: the agent's shell surface filling
/// the drawer, or why there isn't one (exited with a Restart button, a remote
/// that can't run one, a failed spawn). Mounting it starts the shell the
/// first time (the pool keeps it afterwards); unmounting only takes the
/// surface off screen, so the shell and its scrollback live on.
@MainActor final class LeoDrawerTerminalBodyView: NSView {
    private let identity: LeoAgentIdentity
    private let environment: LeoDrawerEnvironment
    private let key: LeoAgentID
    private let messageLabel = NSTextField(wrappingLabelWithString: "")
    private let restartButton = NSButton(title: "Restart", target: nil, action: nil)
    private let messageStack = NSStackView()
    private var surface: Ghostty.SurfaceView?
    private var isShownOnScreen = false
    private var subscription: AnyCancellable?
    private var closeRequestObserver: NSObjectProtocol?

    /// ⌘W with the drawer terminal focused: the pane collapses instead of
    /// closing the agent's main surface (wired by the pane).
    var onCloseRequested: () -> Void = {}

    init(identity: LeoAgentIdentity, environment: LeoDrawerEnvironment) {
        self.identity = identity
        self.environment = environment
        key = LeoDrawerEnvironment.key(for: identity)
        super.init(frame: .zero)
        messageLabel.alignment = .center
        messageLabel.textColor = .secondaryLabelColor
        restartButton.target = self
        restartButton.action = #selector(restart)
        restartButton.bezelStyle = .rounded
        messageStack.orientation = .vertical
        messageStack.spacing = 10
        messageStack.alignment = .centerX
        messageStack.translatesAutoresizingMaskIntoConstraints = false
        messageStack.addArrangedSubview(messageLabel)
        messageStack.addArrangedSubview(restartButton)
        addSubview(messageStack)
        NSLayoutConstraint.activate([
            messageStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            messageStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            messageStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            messageStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
        setAccessibilityLabel("Terminal")
        // The menu route to ⌘W is `close(_:)` below; a binding libghostty handles itself asks
        // to close the surface instead (the process still alive): the same collapse.
        closeRequestObserver = NotificationCenter.default.addObserver(
            forName: Ghostty.Notification.ghosttyCloseSurface, object: nil, queue: .main
        ) { [weak self] note in
            guard note.userInfo?["process_alive"] as? Bool == true, let requested = note.object as? Ghostty.SurfaceView else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.surface === requested else { return }
                self.onCloseRequested()
            }
        }
    }

    deinit {
        if let closeRequestObserver { NotificationCenter.default.removeObserver(closeRequestObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Whether the drawer terminal holds the keyboard.
    var hasFocus: Bool {
        guard let surface, let responder = window?.firstResponder as? NSView else { return false }
        return responder === surface || responder.isDescendant(of: surface)
    }

    // MARK: Lifecycle

    /// Mounted: starts the shell if it hasn't been, and follows the pool.
    func start() {
        environment.pool.open(key, launch: environment.launch(identity))
        subscription = environment.pool.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.render() }
        render()
    }

    /// Unmounted: the surface leaves the screen (and stops drawing); the shell keeps running.
    func stop() {
        subscription = nil
        isShownOnScreen = false
        if let surface {
            LeoSurfaceDrawing.set(surface, visible: false)
            surface.removeFromSuperview()
        }
        surface = nil
    }

    /// Draws or pauses the surface (from `LeoDrawerOcclusion`).
    func setOnScreen(_ visible: Bool) {
        isShownOnScreen = visible
        guard let surface else { return }
        LeoSurfaceDrawing.set(surface, visible: visible)
    }

    func focusTerminal() {
        guard let surface else { return }
        Ghostty.moveFocus(to: surface)
    }

    // MARK: Rendering

    private func render() {
        switch environment.pool.state(for: key) {
        case .running(let running): show(running)
        case .notStarted: showMessage("", canRestart: false)
        case .exited(let status):
            showMessage(status.map { "Shell exited (status \($0))" } ?? "Shell exited", canRestart: true)
        case .unavailable(let message): showMessage(message, canRestart: false)
        case .failed(let message): showMessage("Couldn't start the shell: \(message)", canRestart: true)
        }
    }

    private func show(_ running: Ghostty.SurfaceView) {
        messageStack.isHidden = true
        guard surface !== running else { return }
        let hadFocus = hasFocus
        surface?.removeFromSuperview()
        surface = running
        running.removeFromSuperview()
        running.frame = bounds
        running.autoresizingMask = [.width, .height]
        addSubview(running, positioned: .below, relativeTo: messageStack)
        LeoSurfaceDrawing.set(running, visible: isShownOnScreen)
        if hadFocus { focusTerminal() }
    }

    private func showMessage(_ text: String, canRestart: Bool) {
        let hadFocus = hasFocus
        if let surface {
            LeoSurfaceDrawing.set(surface, visible: false)
            surface.removeFromSuperview()
        }
        surface = nil
        messageLabel.stringValue = text
        restartButton.isHidden = !canRestart
        messageStack.isHidden = false
        if hadFocus { environment.focusMain() }
    }

    @objc private func restart() {
        environment.pool.restart(key, launch: environment.launch(identity))
        focusTerminal()
    }

    // MARK: Responder chain

    /// ⌘W reaches the first responder's chain before the window controller,
    /// which would close the agent's main surface: the drawer takes it.
    @objc func close(_ sender: Any?) { onCloseRequested() }
}
