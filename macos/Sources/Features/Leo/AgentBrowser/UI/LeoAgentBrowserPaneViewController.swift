import AppKit
import Combine

/// An agent's browser in its row's pane: toolbar, the browser's own tab
/// strip, the handoff banner, and the active tab's page. Never takes focus:
/// the pane opens when the agent starts a browser, and only the user's own
/// click goes into the page or the address bar.
///
/// The page shows in `pageSlot` while the pane is on screen; the browser's
/// `viewHost` moves it there and back to the parking window (E5).
final class LeoAgentBrowserPaneViewController: NSViewController {
    let model: LeoAgentBrowserPaneModel
    let toolbar = LeoAgentBrowserToolbar()
    private let separator = NSBox()
    /// The browser's own tabs, under the row pane's strip (`install(tabBar:)`)
    /// and visibly subordinate to it.
    let pageTabBar = LeoEditorTabBar(style: .pages, accessibilityLabel: "Browser tabs")
    private var topSpacer: NSView?
    let banner = LeoHandoffBanner()
    let pageSlot = LeoAgentBrowserSlot()
    private let emptyLabel = NSTextField(labelWithString: "Waiting for the agent to open a page.")
    private let headerTopInset: CGFloat?
    private var subscription: AnyCancellable?

    /// Binds right away: a collapsed split item's view isn't loaded until it is shown.
    init(source: any LeoAgentBrowserPaneSource, headerTopInset: CGFloat? = nil) {
        model = LeoAgentBrowserPaneModel(source: source)
        self.headerTopInset = headerTopInset
        super.init(nibName: nil, bundle: nil)
        wire()
        pageSlot.onVisibilityChange = { [source, weak pageSlot] isVisible in
            guard let pageSlot else { return }
            if isVisible { source.viewHost.show(source, in: pageSlot) } else { source.viewHost.hide(pageSlot) }
        }
        subscription = model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        separator.boxType = .separator
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        pageSlot.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            emptyLabel.centerXAnchor.constraint(equalTo: pageSlot.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: pageSlot.centerYAnchor),
        ])
        pageSlot.setAccessibilityElement(false)
        pageSlot.setContentHuggingPriority(.defaultLow, for: .vertical)

        // Top to bottom: the row pane's strip (installed above these), the
        // browser's tabs, the toolbar, the handoff banner, the page.
        let rows: [NSView] = [pageTabBar, toolbar, separator, banner, pageSlot]
        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .width
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        stack.setAccessibilityLabel("Browser pane")
        NSLayoutConstraint.activate(rows.map { $0.widthAnchor.constraint(equalTo: stack.widthAnchor) })
        if let headerTopInset {
            // Clears the window controls when the titlebar is hidden, as the
            // editor's header does.
            let spacer = NSView()
            spacer.setAccessibilityElement(false)
            stack.insertArrangedSubview(spacer, at: 0)
            spacer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            spacer.heightAnchor.constraint(equalToConstant: headerTopInset).isActive = true
            topSpacer = spacer
        }
        view = stack
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

    private func wire() {
        toolbar.onBack = { [model] in model.goBack() }
        toolbar.onForward = { [model] in model.goForward() }
        toolbar.onReload = { [model] in model.reload() }
        toolbar.onNewTab = { [model] in model.newTab() }
        toolbar.onSubmitURL = { [weak self] in self?.submitURL($0) }
        toolbar.onPill = { [model] in model.pillClicked() }
        toolbar.onGiveBack = { [model] in model.giveBack() }
        banner.onDone = { [model] in model.done() }
        banner.onDecline = { [model] in model.decline() }
        banner.doneButton.isFocusInPane = { [weak self] responder in self?.isFocusOnPaneChrome(responder) ?? false }
        pageTabBar.onSelect = { [weak self] index in
            guard let self, model.tabItems.indices.contains(index) else { return }
            model.selectTab(id: model.tabItems[index].id)
        }
        pageTabBar.onClose = { [weak self] index in
            guard let self, model.tabItems.indices.contains(index) else { return }
            model.closeTab(id: model.tabItems[index].id)
        }
    }

    /// A good address ends editing, so the bar follows the page again --
    /// redirects and the agent's own loads; a bad one stays to be fixed.
    private func submitURL(_ text: String) {
        model.submitURL(text)
        guard model.urlError == nil else { return }
        if toolbar.urlField.currentEditor() != nil { view.window?.makeFirstResponder(nil) }
        refresh()
    }

    /// Where Return answers the handoff banner: focus is in the pane but not in
    /// the page, a text field being edited or Decline -- the user's typing,
    /// a login included, is never taken for an answer.
    private func isFocusOnPaneChrome(_ responder: NSResponder?) -> Bool {
        guard let responder, !(responder is NSText), responder !== banner.declineButton,
              let responderView = responder as? NSView else { return false }
        return responderView.isDescendant(of: view) && !responderView.isDescendant(of: pageSlot)
    }

    private func refresh() {
        guard isViewLoaded else { return }
        toolbar.update(model)
        banner.show(model.handoff)
        pageTabBar.update(model.tabItems.map {
            LeoEditorTabBar.Item(title: $0.title, toolTip: $0.title, isDirty: false, isSelected: $0.isActive)
        })
        pageTabBar.isHidden = model.tabItems.count < 2
        emptyLabel.isHidden = model.source.activeView != nil
    }
}
