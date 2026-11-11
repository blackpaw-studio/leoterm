import AppKit
import Combine
import LeoKit

/// A plugin view in its row's pane (slot 1): the row pane's strip on top, a
/// Back bar while a pushed view is showing, then the slot's content drawn by
/// the renderers. It never asks for focus; the person's own click does.
///
/// The slot's content is drawn by the shared `LeoPluginSlotHostView`, which
/// follows the slot store (Loading until the plugin renders, Error with Retry,
/// a notice when the plugin is off or gone); this controller adds the strip and
/// the Back bar.
final class LeoPluginPaneViewController: NSViewController {
    let ref: LeoPluginViewRef
    private let host: any LeoPluginPaneHosting
    private let headerTopInset: LeoToolbarInset?
    private let backBar = LeoPluginBackBar()
    private lazy var slotHost = LeoPluginSlotHostView(key: ref.slotKey, surface: host)
    private var topSpacer: NSView?
    private var insetSubscription: AnyCancellable?

    /// Binds right away: a collapsed split item's view isn't loaded until it is shown.
    init(ref: LeoPluginViewRef, host: any LeoPluginPaneHosting, headerTopInset: LeoToolbarInset? = nil) {
        self.ref = ref
        self.host = host
        self.headerTopInset = headerTopInset
        super.init(nibName: nil, bundle: nil)
        backBar.onBack = { [weak self] in
            guard let self else { return }
            self.host.pop(self.ref.slotKey)
        }
    }

    required init?(coder: NSCoder) { nil }

    /// The slot's content as drawn now (for tests and the visual check).
    var shownContent: LeoPluginSlotContent? { slotHost.content }
    var isBackBarVisible: Bool { !backBar.isHidden }

    override func loadView() {
        let root = LeoPluginPaneRootView()
        root.orientation = .vertical
        root.spacing = 0
        root.alignment = .width
        root.setAccessibilityLabel("\(ref.title), \(ref.pluginName)")
        slotHost.setContentHuggingPriority(.defaultLow, for: .vertical)
        slotHost.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        slotHost.onContentChange = { [weak self] content in self?.showBackBar(for: content) }
        let rows: [NSView] = [backBar, slotHost]
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
        slotHost.refresh()
        showBackBar(for: slotHost.content)
    }

    private func showBackBar(for content: LeoPluginSlotContent?) {
        if case .nodes(_, let isPushed)? = content { backBar.isHidden = !isPushed } else { backBar.isHidden = true }
    }
}

/// The pane's root: the editor's background.
private final class LeoPluginPaneRootView: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { layer?.backgroundColor = NSColor.textBackgroundColor.cgColor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wantsLayer = true
    }
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
