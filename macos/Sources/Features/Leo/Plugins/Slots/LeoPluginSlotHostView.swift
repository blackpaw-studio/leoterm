import AppKit
import Combine
import LeoKit
import SwiftUI

/// The one host for a slot's content: Loading until the plugin renders, the
/// tree through the renderers, Error with Retry, a notice for a plugin that is
/// off or gone. The row pane and the palette page both use it, so they show
/// and behave alike. It follows the slot through `LeoPluginSlotSurface` and
/// tells it when the slot is on screen; it never reaches the manager itself.
final class LeoPluginSlotHostView: NSView {
    let key: LeoPluginSlotKey
    private let surface: any LeoPluginSlotSurface
    private let mint = LeoPluginGestureMint()
    /// Whether the slot's first focusable view takes the keyboard (the palette
    /// page does, so Return and the arrows reach its list; a pane waits for a click).
    private let takesFocus: Bool
    private var nodeView: LeoPluginNodeView?
    private var shown: NSView?
    private var visibility: LeoPluginVisibilityReporter
    private var isWindowClosed = false
    private var windowObservers: [NSObjectProtocol] = []
    private var subscription: AnyCancellable?

    /// What it shows now (for tests and the pane's Back bar).
    private(set) var content: LeoPluginSlotContent?
    /// Fires when the content changes, so a pane can show or hide its Back bar.
    var onContentChange: (LeoPluginSlotContent) -> Void = { _ in }
    /// The shown content's natural height when it scrolls (a form), else nil.
    var onPreferredHeightChange: (CGFloat?) -> Void = { _ in }

    @MainActor init(key: LeoPluginSlotKey, surface: any LeoPluginSlotSurface, takesFocus: Bool = false) {
        self.key = key
        self.surface = surface
        self.takesFocus = takesFocus
        visibility = LeoPluginVisibilityReporter(key: key, surface: surface)
        super.init(frame: .zero)
        refresh()
        // `changes` fires before the change lands; the hop reads the new state.
        subscription = surface.changes
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    @MainActor func refresh() {
        let next = surface.content(for: key)
        guard next != content else { return }
        let previous = content
        content = next
        switch next {
        case .loading:
            show(LeoPluginLoadingView(loading: .init(message: nil)))
        case .nodes(let nodes, let isPushed):
            if case .nodes(_, let wasPushed)? = previous, wasPushed == isPushed, let nodeView {
                nodeView.render(nodes)
            } else {
                let view = LeoPluginNodeView(emitter: emitter)
                view.onPreferredHeightChange = { [weak self] in self?.onPreferredHeightChange($0) }
                view.render(nodes)
                nodeView = view
                show(view)
            }
        case .error(let message):
            let retry = LeoPluginAction.callback(id: "retry", payload: .null)
            show(LeoPluginErrorView(error: .init(message: message, retry: retry), emitter: emitter))
        case .notice(let message):
            show(LeoPluginEmptyStateView(state: .init(title: message, sfSymbol: "puzzlepiece.extension"), emitter: emitter))
        }
        focusIfNeeded()
        onContentChange(next)
    }

    private var emitter: LeoPluginActionEmitter {
        LeoPluginActionEmitter(mint: mint) { [weak self] action, gesture in self?.handle(action, gesture) }
    }

    /// The only thing a host-level error offers is Retry; anything else is the plugin's own action.
    private func handle(_ action: LeoPluginAction, _ gesture: LeoPluginGesture?) {
        if case .error? = content {
            surface.retry(key)
        } else {
            surface.perform(action, gesture: gesture, in: key)
        }
    }

    private func show(_ next: NSView) {
        shown?.removeFromSuperview()
        if !(next is LeoPluginNodeView) {
            nodeView = nil
            onPreferredHeightChange(nil)
        }
        shown = next
        next.translatesAutoresizingMaskIntoConstraints = false
        addSubview(next)
        NSLayoutConstraint.activate([
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
            next.trailingAnchor.constraint(equalTo: trailingAnchor),
            next.topAnchor.constraint(equalTo: topAnchor),
            next.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: Focus

    /// Moves focus into the slot unless it is already inside it.
    @MainActor private func focusIfNeeded() {
        guard takesFocus, let window else { return }
        if let current = window.firstResponder as? NSView, current.isDescendant(of: self) { return }
        guard let target = Self.firstFocusable(in: self) else { return }
        window.makeFirstResponder(target)
    }

    private static func firstFocusable(in view: NSView) -> NSView? {
        for child in view.subviews {
            if child.acceptsFirstResponder { return child }
            if let found = firstFocusable(in: child) { return found }
        }
        return nil
    }

    // MARK: Visibility

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        isWindowClosed = false
        guard let newWindow else { return }
        // A closed window keeps its views, so leaving it is not reported by AppKit.
        let center = NotificationCenter.default
        windowObservers = [
            center.addObserver(forName: NSWindow.willCloseNotification, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowClosed = true; self?.reportVisibility() }
            },
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.isWindowClosed = false; self?.reportVisibility() }
            },
        ]
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportVisibility()
        // The window isn't key yet inside a SwiftUI hop; focus on the next turn.
        Task { @MainActor [weak self] in self?.focusIfNeeded() }
    }

    override func viewDidHide() { super.viewDidHide(); reportVisibility() }
    override func viewDidUnhide() { super.viewDidUnhide(); reportVisibility() }

    private func reportVisibility() {
        let visible = window != nil && !isWindowClosed && !isHiddenOrHasHiddenAncestor
        MainActor.assumeIsolated { visibility.setAppeared(visible) }
    }

    deinit { windowObservers.forEach(NotificationCenter.default.removeObserver) }
}

/// The host inside SwiftUI (the palette page).
struct LeoPluginSlotHostRepresentable: NSViewRepresentable {
    let key: LeoPluginSlotKey
    let surface: any LeoPluginSlotSurface
    var takesFocus = false
    /// Called (off the layout pass) with the content's natural height when it scrolls.
    var onPreferredHeightChange: (CGFloat?) -> Void = { _ in }

    func makeNSView(context: Context) -> LeoPluginSlotHostView {
        let host = LeoPluginSlotHostView(key: key, surface: surface, takesFocus: takesFocus)
        let report = onPreferredHeightChange
        host.onPreferredHeightChange = { height in DispatchQueue.main.async { report(height) } }
        return host
    }

    func updateNSView(_ nsView: LeoPluginSlotHostView, context: Context) {}
}
