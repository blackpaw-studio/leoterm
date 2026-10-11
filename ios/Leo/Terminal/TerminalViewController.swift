import ComposableArchitecture
import LeoFeatures
import SwiftTerm
import UIKit
import UIKitNavigation

/// An agent's tmux session, read-only. The emulator is sized to the
/// requested Mac-sized grid and sits in a zooming scroll view: it starts
/// fitted to the screen's width; pinch to zoom, drag to pan, double-tap to
/// toggle between fitted and actual size. The keyboard never appears.
final class TerminalViewController: UIViewController, UIScrollViewDelegate {
    private static let maximumZoom: CGFloat = 4
    /// Keeps the zoomed backing store within what a layer can hold.
    private static let maximumBackingPixels: CGFloat = 8192

    @UIBindable private var store: StoreOf<LeoFeatures.Terminal>
    @Dependency(\.terminalOutput) private var output
    private let zoomView = UIScrollView()
    private let terminalView = ReadOnlyTerminalView(frame: .zero, font: .monospacedSystemFont(ofSize: 12, weight: .regular))
    private let banner = TerminalBanner()
    private var outputTask: Task<Void, Never>?
    private var appliedSize: TerminalSize?
    private var isFittedToWidth = true

    init(store: StoreOf<LeoFeatures.Terminal>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { outputTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = store.agentName
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = TerminalPalette.background

        terminalView.isUserInteractionEnabled = false
        terminalView.isScrollEnabled = false
        terminalView.nativeBackgroundColor = TerminalPalette.background
        terminalView.nativeForegroundColor = TerminalPalette.foreground
        terminalView.accessibilityIdentifier = "terminal.screen"

        zoomView.delegate = self
        zoomView.maximumZoomScale = Self.maximumZoom
        zoomView.bouncesZoom = true
        zoomView.showsHorizontalScrollIndicator = true
        zoomView.contentInsetAdjustmentBehavior = .always
        zoomView.indicatorStyle = .white
        zoomView.translatesAutoresizingMaskIntoConstraints = false
        zoomView.addSubview(terminalView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        zoomView.addGestureRecognizer(doubleTap)
        view.addSubview(zoomView)

        banner.translatesAutoresizingMaskIntoConstraints = false
        banner.onRetry = { [weak self] in self?.store.send(.retryButtonTapped) }
        view.addSubview(banner)
        NSLayoutConstraint.activate([
            zoomView.topAnchor.constraint(equalTo: view.topAnchor),
            zoomView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            zoomView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            zoomView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            banner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            banner.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
        ])

        let ref = store.ref
        let stream = output.output(for: ref)
        outputTask = Task { [weak self] in
            for await chunk in stream {
                self?.apply(chunk)
            }
        }

        observe { [weak self] in
            guard let self else { return }
            render()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        store.send(.appeared)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        store.send(.disappeared)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateZoomLimits()
    }

    // MARK: Rendering

    private func render() {
        applySize(store.size)
        navigationItem.subtitle = subtitle
        navigationItem.rightBarButtonItem = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: sizeMenu())
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Terminal Size")
        banner.show(bannerContent)
        contentUnavailableConfiguration = unavailableConfiguration
        zoomView.isHidden = contentUnavailableConfiguration != nil
    }

    private var subtitle: String {
        let size = "\(store.size.cols)×\(store.size.rows)"
        switch store.phase {
        case .live: return String(localized: "Live · \(size) · read-only")
        case .connecting: return String(localized: "Connecting…")
        case .disconnected: return String(localized: "Disconnected")
        case .revoked: return String(localized: "Access revoked")
        case .notRunning: return String(localized: "Not running")
        case .paused, .idle: return String(localized: "Paused")
        }
    }

    private var bannerContent: TerminalBanner.Content? {
        switch store.phase {
        case .connecting where store.failures > 0:
            return .init(text: String(localized: "Reconnecting…"), tint: .systemOrange, isBusy: true, canRetry: false)
        case .connecting:
            return .init(text: String(localized: "Connecting…"), tint: .systemOrange, isBusy: true, canRetry: false)
        case .disconnected(let attempt, let reason):
            return .init(text: String(localized: "Disconnected — retrying (\(attempt))\n\(reason)"), tint: .systemOrange, isBusy: false, canRetry: true)
        case .live, .idle, .paused, .revoked, .notRunning:
            return nil
        }
    }

    private var unavailableConfiguration: UIContentUnavailableConfiguration? {
        var configuration = UIContentUnavailableConfiguration.empty()
        switch store.phase {
        case .revoked:
            configuration.image = UIImage(systemName: "lock.slash")
            configuration.text = String(localized: "Access Revoked")
            configuration.secondaryText = String(localized: "\(store.daemon.name) no longer accepts this device. Pair it again to watch \(store.agentName).")
        case .notRunning:
            configuration.image = UIImage(systemName: "stop.circle")
            configuration.text = String(localized: "\(store.agentName) Isn't Running")
            configuration.secondaryText = String(localized: "Start the agent to watch its terminal. This view reconnects when it starts.")
        default:
            return nil
        }
        configuration.textProperties.color = TerminalPalette.foreground
        configuration.secondaryTextProperties.color = TerminalPalette.secondary
        configuration.imageProperties.tintColor = TerminalPalette.secondary
        return configuration
    }

    private func sizeMenu() -> UIMenu {
        let sizes = TerminalSize.presets.map { size in
            UIAction(title: "\(size.cols) × \(size.rows)", state: size == store.size ? .on : .off) { [weak self] _ in
                self?.store.send(.sizeSelected(size))
            }
        }
        let fit = UIAction(title: String(localized: "Fit Width"), image: UIImage(systemName: "arrow.left.and.right")) { [weak self] _ in
            self?.zoom(fit: true)
        }
        let actual = UIAction(title: String(localized: "Actual Size"), image: UIImage(systemName: "1.magnifyingglass")) { [weak self] _ in
            self?.zoom(fit: false)
        }
        return UIMenu(children: [
            UIMenu(title: String(localized: "Columns × Rows (match your Mac's window)"), options: .displayInline, children: sizes),
            UIMenu(options: .displayInline, children: [fit, actual]),
        ])
    }

    // MARK: Terminal

    private func apply(_ chunk: TerminalOutput) {
        switch chunk {
        case .reset:
            terminalView.getTerminal().resetToInitialState()
            appliedSize = nil
            applySize(store.size)
        case .bytes(let data):
            terminalView.feed(byteArray: ArraySlice(data))
        }
    }

    /// Sizes the emulator to exactly `size` cells (it derives its grid from
    /// its frame; the half point guards against rounding down a row).
    private func applySize(_ size: TerminalSize) {
        guard size != appliedSize else { return }
        appliedSize = size
        terminalView.getTerminal().resize(cols: size.cols, rows: size.rows)
        let optimal = terminalView.getOptimalFrameSize().size
        let zoom = zoomView.zoomScale
        zoomView.zoomScale = 1
        terminalView.frame = CGRect(origin: .zero, size: CGSize(width: optimal.width + 0.5, height: optimal.height + 0.5))
        zoomView.contentSize = terminalView.frame.size
        zoomView.zoomScale = zoom
        isFittedToWidth = true
        updateZoomLimits()
    }

    private func updateZoomLimits() {
        let width = terminalView.bounds.width
        guard width > 0, zoomView.bounds.width > 0 else { return }
        let available = zoomView.bounds.inset(by: zoomView.adjustedContentInset).width
        let fit = min(1, available / width)
        zoomView.minimumZoomScale = fit
        if isFittedToWidth || zoomView.zoomScale < fit { zoomView.zoomScale = fit }
        sharpen()
    }

    private func zoom(fit: Bool) {
        isFittedToWidth = fit
        zoomView.setZoomScale(fit ? zoomView.minimumZoomScale : 1, animated: true)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        let isFitted = abs(zoomView.zoomScale - zoomView.minimumZoomScale) < 0.01
        guard isFitted else { return zoom(fit: true) }
        isFittedToWidth = false
        let point = gesture.location(in: terminalView)
        let size = CGSize(width: zoomView.bounds.width, height: zoomView.bounds.height)
        zoomView.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), animated: true)
    }

    /// Re-renders the emulator at the zoomed resolution so text stays crisp.
    private func sharpen() {
        let screenScale = view.window?.windowScene?.screen.scale ?? traitCollection.displayScale
        let widest = max(terminalView.bounds.width, terminalView.bounds.height, 1)
        let scale = min(screenScale * max(zoomView.zoomScale, 1), Self.maximumBackingPixels / widest)
        guard abs(terminalView.contentScaleFactor - scale) > 0.01 else { return }
        terminalView.contentScaleFactor = scale
        terminalView.layer.contentsScale = scale
        terminalView.setNeedsDisplay()
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { terminalView }

    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        isFittedToWidth = false
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        isFittedToWidth = abs(scale - scrollView.minimumZoomScale) < 0.01
        sharpen()
    }
}

/// SwiftTerm's view made read-only: it never becomes first responder, so
/// no keyboard; with no delegate, anything the emulator would send back
/// (query replies) is dropped.
final class ReadOnlyTerminalView: TerminalView {
    override var canBecomeFirstResponder: Bool { false }
    override var canBecomeFocused: Bool { false }
}

/// The terminal canvas is dark in both appearances, like a terminal.
enum TerminalPalette {
    static let background = UIColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    static let foreground = UIColor(red: 0.88, green: 0.89, blue: 0.91, alpha: 1)
    static let secondary = UIColor(white: 0.6, alpha: 1)
}

/// A floating status capsule over the terminal: connecting, or dropped
/// with a retry button.
final class TerminalBanner: UIView {
    struct Content: Equatable {
        let text: String
        let tint: UIColor
        let isBusy: Bool
        let canRetry: Bool
    }

    var onRetry: (() -> Void)?
    private let label = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let retry = UIButton(configuration: .plain())
    private var content: Content?

    override init(frame: CGRect) {
        super.init(frame: frame)
        let effect = UIVisualEffectView(effect: UIGlassEffect())
        effect.translatesAutoresizingMaskIntoConstraints = false
        effect.layer.cornerRadius = 18
        effect.layer.cornerCurve = .continuous
        effect.clipsToBounds = true
        label.font = .preferredFont(forTextStyle: .footnote).withWeight(.semibold)
        label.numberOfLines = 2
        label.adjustsFontForContentSizeCategory = true
        spinner.color = .white
        retry.configuration?.title = String(localized: "Retry")
        retry.configuration?.buttonSize = .small
        retry.addAction(UIAction { [weak self] _ in self?.onRetry?() }, for: .primaryActionTriggered)
        let stack = UIStackView(arrangedSubviews: [spinner, label, retry])
        stack.spacing = 8
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effect)
        effect.contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            effect.topAnchor.constraint(equalTo: topAnchor),
            effect.bottomAnchor.constraint(equalTo: bottomAnchor),
            effect.leadingAnchor.constraint(equalTo: leadingAnchor),
            effect.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: effect.contentView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: effect.contentView.bottomAnchor, constant: -8),
            stack.leadingAnchor.constraint(equalTo: effect.contentView.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: effect.contentView.trailingAnchor, constant: -10),
        ])
        accessibilityIdentifier = "terminal.banner"
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ content: Content?) {
        guard content != self.content else { return }
        self.content = content
        isHidden = content == nil
        guard let content else { return }
        label.text = content.text
        label.textColor = content.tint
        content.isBusy ? spinner.startAnimating() : spinner.stopAnimating()
        spinner.isHidden = !content.isBusy
        retry.isHidden = !content.canRetry
        accessibilityLabel = content.text
    }
}
