import AppKit
import Combine
import LeoKit

/// A plugin view in its row's pane (slot 1): the row pane's strip on top, a
/// Back bar while a pushed view is showing, then the slot's content drawn by
/// the renderers. It never asks for focus; the person's own click does.
///
/// Reads everything through `LeoPluginPaneHosting`, so what it shows follows
/// the slot store (Loading until the plugin renders, Error with Retry, a
/// notice when the plugin is off or gone).
final class LeoPluginPaneViewController: NSViewController {
    let ref: LeoPluginViewRef
    private let host: any LeoPluginPaneHosting
    private let headerTopInset: LeoToolbarInset?
    private let mint = LeoPluginGestureMint()
    private let backBar = LeoPluginBackBar()
    private let body = NSView()
    private var topSpacer: NSView?
    private var shown: NSView?
    private var nodeView: LeoPluginNodeView?
    private var content: LeoPluginSlotContent?
    private var isVisible = false
    private var subscription: AnyCancellable?
    private var insetSubscription: AnyCancellable?

    /// Binds right away: a collapsed split item's view isn't loaded until it is shown.
    init(ref: LeoPluginViewRef, host: any LeoPluginPaneHosting, headerTopInset: LeoToolbarInset? = nil) {
        self.ref = ref
        self.host = host
        self.headerTopInset = headerTopInset
        super.init(nibName: nil, bundle: nil)
        backBar.onBack = { [weak self] in
            guard let self else { return }
            self.host.pop(self.ref)
        }
        subscription = host.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    /// The slot's content as drawn now (for tests and the visual check).
    var shownContent: LeoPluginSlotContent? { content }
    var isBackBarVisible: Bool { !backBar.isHidden }

    override func loadView() {
        let root = LeoPluginPaneRootView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        root.setAccessibilityLabel("\(ref.title), \(ref.pluginName)")
        root.onVisibilityChange = { [weak self] in self?.setVisible($0) }
        body.setContentHuggingPriority(.defaultLow, for: .vertical)
        body.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        let rows: [NSView] = [backBar, body]
        rows.forEach(root.addArrangedSubview)
        NSLayoutConstraint.activate(rows.map { $0.widthAnchor.constraint(equalTo: root.widthAnchor) })
        if let headerTopInset {
            // Clears the window controls when the titlebar is hidden, as the editor's header does.
            let spacer = NSView()
            spacer.setAccessibilityElement(false)
            root.insertArrangedSubview(spacer, at: 0)
            spacer.widthAnchor.constraint(equalTo: root.widthAnchor).isActive = true
            let height = spacer.heightAnchor.constraint(equalToConstant: headerTopInset.headerTop)
            height.isActive = true
            insetSubscription = headerTopInset.$height.sink { [weak height] toolbarHeight in
                height?.constant = LeoToolbarInset.headerTop(forHeight: toolbarHeight)
            }
            topSpacer = spacer
        }
        view = root
        view.widthAnchor.constraint(greaterThanOrEqualToConstant: LeoEditorPaneViewController.minimumWidth).isActive = true
        content = nil
        refresh()
    }

    /// Puts the row pane's tab strip at the top of the pane.
    func install(tabBar: NSView) {
        guard let stack = view as? NSStackView, tabBar.superview !== stack else { return }
        tabBar.removeFromSuperview()
        stack.insertArrangedSubview(tabBar, at: topSpacer == nil ? 0 : 1)
        tabBar.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    // MARK: Content

    func refresh() {
        guard isViewLoaded else { return }
        let next = host.slotContent(for: ref)
        guard next != content else { return }
        let previous = content
        content = next
        switch next {
        case .loading:
            show(LeoPluginLoadingView(loading: .init(message: nil)), pushed: false)
        case .nodes(let nodes, let isPushed):
            if case .nodes(_, let wasPushed)? = previous, wasPushed == isPushed, let nodeView {
                nodeView.render(nodes)
            } else {
                let view = LeoPluginNodeView(emitter: emitter)
                view.render(nodes)
                nodeView = view
                show(view, pushed: isPushed)
            }
        case .error(let message):
            let retry = LeoPluginAction.callback(id: "retry", payload: .null)
            show(LeoPluginErrorView(error: .init(message: message, retry: retry), emitter: emitter), pushed: false)
        case .notice(let message):
            show(LeoPluginEmptyStateView(state: .init(title: message, sfSymbol: "puzzlepiece.extension"), emitter: emitter), pushed: false)
        }
    }

    private var emitter: LeoPluginActionEmitter {
        LeoPluginActionEmitter(mint: mint) { [weak self] action, gesture in self?.handle(action, gesture) }
    }

    /// The only thing a host-level error offers is Retry; anything else is the plugin's own action.
    private func handle(_ action: LeoPluginAction, _ gesture: LeoPluginGesture?) {
        if case .error? = content {
            host.retry(ref)
        } else {
            host.perform(action, gesture: gesture, in: ref)
        }
    }

    private func show(_ next: NSView, pushed: Bool) {
        shown?.removeFromSuperview()
        if !(next is LeoPluginNodeView) { nodeView = nil }
        shown = next
        backBar.isHidden = !pushed
        next.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            next.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            next.topAnchor.constraint(equalTo: body.topAnchor),
            next.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    // MARK: Visibility

    private func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        host.setVisible(ref, visible)
    }
}

/// The pane's root: the editor's background, and the one place that notices
/// the pane coming on or going off screen.
private final class LeoPluginPaneRootView: NSStackView {
    var onVisibilityChange: (Bool) -> Void = { _ in }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
        report()
    }

    override func viewDidHide() { super.viewDidHide(); report() }
    override func viewDidUnhide() { super.viewDidUnhide(); report() }

    private func report() { onVisibilityChange(window != nil && !isHiddenOrHasHiddenAncestor) }
}

/// "‹ Back" under the strip while a pushed view is showing.
private final class LeoPluginBackBar: NSView {
    var onBack: () -> Void = {}
    private let button = NSButton(title: "Back", target: nil, action: nil)

    override init(frame: NSRect) {
        super.init(frame: frame)
        button.image = LeoPluginRenderStyle.symbol("chevron.left", pointSize: 11, weight: .semibold)
        button.imagePosition = .imageLeading
        button.bezelStyle = .accessoryBarAction
        button.target = self
        button.action = #selector(back)
        button.toolTip = "Back"
        let separator = NSBox()
        separator.boxType = .separator
        [button, separator].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            button.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func back() { onBack() }
}
