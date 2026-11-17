import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit
import WebKit

/// One agent's browser on iPhone (B-305), pushed from its detail. The page
/// the agent drives, with what the user needs around it: the address bar
/// with back and forward (hold for history), the tabs, the control pill,
/// and bars for a handoff, a permission ask, a page's dialog, or why a page
/// couldn't load. The browser itself keeps running while this pane is gone.
final class AgentBrowserViewController: UIViewController, UITextFieldDelegate {
    private let store: StoreOf<AgentBrowser>
    private let browser: LeoIOSAgentBrowser?
    private var stopObserving: (() -> Void)?

    private let backButton = UIButton(configuration: .plain())
    private let forwardButton = UIButton(configuration: .plain())
    private let reloadButton = UIButton(configuration: .plain())
    private let addressField = UITextField()
    private let bars = UIStackView()
    private let refusalBar = AgentBrowserBar(id: "browser.refusal")
    private let handoffBar = AgentBrowserBar(id: "browser.handoff")
    private let permissionBar = AgentBrowserBar(id: "browser.permission")
    private let dialogBar = AgentBrowserBar(id: "browser.dialog")
    private let stage = UIView()
    private let pill = AgentBrowserControlPill()
    private let tabsItem = UIBarButtonItem(image: UIImage(systemName: "square.on.square"), menu: nil)
    private let moreItem = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: nil)

    /// `browser` is nil when this iPhone can't run one (the setting is off).
    init(store: StoreOf<AgentBrowser>, browser: LeoIOSAgentBrowser?) {
        self.store = store
        self.browser = browser
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Browser")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        view.accessibilityIdentifier = "browser.pane"
        tabsItem.accessibilityLabel = String(localized: "Tabs")
        tabsItem.accessibilityIdentifier = "browser.tabs"
        moreItem.accessibilityLabel = String(localized: "More")
        moreItem.accessibilityIdentifier = "browser.more"
        navigationItem.rightBarButtonItems = [moreItem, tabsItem]
        layout()
        pill.onTakeControl = { [weak self] in self?.store.send(.takeControlTapped) }
        pill.onGiveBack = { [weak self] in self?.store.send(.handBackTapped) }
        stopObserving = browser?.observe { [weak self] in self?.render() }
        render()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        browser?.openBlankTabIfEmpty()
        render()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        browser?.viewHost.clear(stage)
        browser?.paneHidden()
    }

    isolated deinit {
        stopObserving?()
    }

    // MARK: - Layout

    private func layout() {
        configure(backButton, symbol: "chevron.backward", label: String(localized: "Back"), id: "browser.back") { $0.browser?.goBack() }
        configure(forwardButton, symbol: "chevron.forward", label: String(localized: "Forward"), id: "browser.forward") { $0.browser?.goForward() }
        configure(reloadButton, symbol: "arrow.clockwise", label: String(localized: "Reload"), id: "browser.reload") { controller in
            guard let browser = controller.browser else { return }
            if browser.isLoading { browser.activeWebView?.stopLoading() } else { browser.reload() }
        }
        addressField.borderStyle = .roundedRect
        addressField.placeholder = String(localized: "Address")
        addressField.keyboardType = .URL
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.returnKeyType = .go
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL
        addressField.font = .preferredFont(forTextStyle: .callout)
        addressField.adjustsFontForContentSizeCategory = true
        addressField.accessibilityIdentifier = "browser.address"
        addressField.delegate = self
        let addressRow = UIStackView(arrangedSubviews: [backButton, forwardButton, addressField, reloadButton])
        addressRow.spacing = 2
        addressRow.alignment = .center

        bars.axis = .vertical
        bars.spacing = 8
        [refusalBar, handoffBar, permissionBar, dialogBar].forEach(bars.addArrangedSubview)
        stage.clipsToBounds = true
        stage.accessibilityIdentifier = "browser.stage"
        let column = UIStackView(arrangedSubviews: [addressRow, bars])
        column.axis = .vertical
        column.spacing = 8
        [column, stage, pill].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        let margins = view.layoutMarginsGuide
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            column.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            stage.topAnchor.constraint(equalTo: column.bottomAnchor, constant: 8),
            stage.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stage.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stage.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            pill.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            pill.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    private func configure(
        _ button: UIButton, symbol: String, label: String, id: String, action: @escaping (AgentBrowserViewController) -> Void
    ) {
        button.configuration?.image = UIImage(systemName: symbol)
        button.accessibilityLabel = label
        button.accessibilityIdentifier = id
        button.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            action(self)
        }, for: .primaryActionTriggered)
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    // MARK: - Rendering

    private func render() {
        guard isViewLoaded else { return }
        guard let browser else { return renderUnavailable() }
        let control = browser.control.state
        let webView = browser.activeWebView
        if let webView {
            browser.viewHost.show(webView, on: stage)
            contentUnavailableConfiguration = nil
        } else {
            browser.viewHost.clear(stage)
            contentUnavailableConfiguration = emptyState(browser)
        }
        if !addressField.isFirstResponder { addressField.text = Self.addressText(browser.activeURL) }
        backButton.isEnabled = browser.canGoBack
        forwardButton.isEnabled = browser.canGoForward
        backButton.menu = historyMenu(browser, back: true)
        forwardButton.menu = historyMenu(browser, back: false)
        reloadButton.configuration?.image = UIImage(systemName: browser.isLoading ? "xmark" : "arrow.clockwise")
        reloadButton.accessibilityLabel = browser.isLoading ? String(localized: "Stop") : String(localized: "Reload")
        reloadButton.isEnabled = webView != nil
        tabsItem.menu = tabsMenu(browser)
        moreItem.menu = moreMenu(browser, control: control)
        renderRefusal(browser)
        renderHandoff(control)
        renderPermission(browser)
        renderDialog(browser)
        pill.isHidden = webView == nil
        if webView != nil { pill.show(control) }
    }

    private func renderUnavailable() {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "globe")
        configuration.text = String(localized: "Browser Is Off")
        configuration.secondaryText = String(localized: "Turn on Agent Browser on This iPhone in Settings.")
        contentUnavailableConfiguration = configuration
        [refusalBar, handoffBar, permissionBar, dialogBar, pill].forEach { $0.isHidden = true }
    }

    private func emptyState(_ browser: LeoIOSAgentBrowser) -> UIContentUnavailableConfiguration {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "globe")
        configuration.text = String(localized: "No Open Pages")
        configuration.secondaryText = String(localized: "Pages \(store.displayName) opens show here.")
        var button = UIButton.Configuration.borderedTinted()
        button.title = String(localized: "New Tab")
        configuration.button = button
        configuration.buttonProperties.primaryAction = UIAction { [weak browser] _ in browser?.openBlankTab() }
        return configuration
    }

    /// The address as the user reads it; blank for a blank tab.
    static func addressText(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }

    private func renderRefusal(_ browser: LeoIOSAgentBrowser) {
        guard let refusal = browser.refusal else { return refusalBar.isHidden = true }
        refusalBar.isHidden = false
        let isLocalhost = refusal.code == .localhostUnreachable
        refusalBar.configure(
            symbol: isLocalhost ? "network.slash" : "exclamationmark.triangle", tint: .systemOrange,
            heading: isLocalhost ? String(localized: "Can’t reach \(store.machineName)’s localhost") : nil,
            message: refusal.message, buttons: []
        )
    }

    private func renderHandoff(_ control: LeoBrowserControl) {
        guard let handoff = control.pendingHandoff else { return handoffBar.isHidden = true }
        handoffBar.isHidden = false
        let requestID = handoff.requestID
        handoffBar.configure(
            symbol: "hand.raised.fill", heading: String(localized: "\(store.displayName) needs you"), message: handoff.message,
            buttons: [
                .init(title: String(localized: "Decline"), id: "browser.handoff.decline") { [weak self] in
                    self?.store.send(.handoffDeclineTapped(requestID: requestID))
                },
                .init(title: String(localized: "Done"), id: "browser.handoff.done") { [weak self] in
                    self?.store.send(.handoffDoneTapped(requestID: requestID))
                },
            ]
        )
    }

    private func renderPermission(_ browser: LeoIOSAgentBrowser) {
        guard let prompt = browser.pendingPermission else { return permissionBar.isHidden = true }
        permissionBar.isHidden = false
        permissionBar.configure(
            symbol: prompt.request.kind == .microphone ? "mic.fill" : "video.fill", heading: nil, message: prompt.message,
            detail: String(localized: "Only you can answer. Your answer lasts until this tab closes."),
            buttons: [
                .init(title: String(localized: "Don’t Allow"), id: "browser.permission.deny") { [weak browser] in
                    browser?.answerPermission(prompt, allow: false)
                },
                .init(title: String(localized: "Allow"), id: "browser.permission.allow") { [weak browser] in
                    browser?.answerPermission(prompt, allow: true)
                },
            ]
        )
    }

    private func renderDialog(_ browser: LeoIOSAgentBrowser) {
        guard let prompt = browser.pendingDialog else { return dialogBar.isHidden = true }
        let isNew = dialogBar.isHidden || dialogBar.tag != prompt.id
        dialogBar.isHidden = false
        dialogBar.tag = prompt.id
        if isNew { dialogBar.textField.text = prompt.dialog.defaultText ?? "" }
        let bar = dialogBar
        let answer: (Bool) -> AgentBrowserBar.Button = { [weak browser, weak bar] accepted in
            .init(title: LeoBrowserDialogText.buttonTitle(prompt.kind, accepted: accepted), id: "browser.dialog.\(accepted ? "accept" : "dismiss")") {
                let text = prompt.kind == .prompt && accepted ? bar?.textField.text : nil
                browser?.answerDialog(prompt, accept: accepted, text: text)
            }
        }
        dialogBar.configure(
            symbol: "text.bubble", heading: prompt.header, message: prompt.message, detail: prompt.detail,
            text: prompt.kind == .prompt ? (dialogBar.textField.text ?? "") : nil,
            buttons: prompt.kind == .alert ? [answer(true)] : [answer(false), answer(true)]
        )
    }

    // MARK: - Menus

    private func historyMenu(_ browser: LeoIOSAgentBrowser, back: Bool) -> UIMenu? {
        let items = browser.history(back: back)
        guard !items.isEmpty else { return nil }
        return UIMenu(children: items.map { item in
            UIAction(title: item.title.flatMap { $0.isEmpty ? nil : $0 } ?? item.url.absoluteString, subtitle: item.url.host()) { [weak browser] _ in
                browser?.go(to: item)
            }
        })
    }

    private func tabsMenu(_ browser: LeoIOSAgentBrowser) -> UIMenu {
        let tabs = browser.tabSet.tabs.map { tab in
            UIAction(
                title: tab.title.isEmpty ? (Self.addressText(tab.url).isEmpty ? String(localized: "New Tab") : Self.addressText(tab.url)) : tab.title,
                subtitle: tab.url?.host(), state: tab.isActive ? .on : .off
            ) { [weak browser] _ in browser?.selectTab(tab.id) }
        }
        let isFull = browser.tabSet.tabs.count >= LeoBrowserLimits.maximumTabs
        var actions: [UIMenuElement] = [
            UIAction(title: String(localized: "New Tab"), image: UIImage(systemName: "plus"), attributes: isFull ? .disabled : []) { [weak browser] _ in
                browser?.openBlankTab()
            },
        ]
        if let active = browser.tabSet.activeTabID {
            actions.append(UIAction(title: String(localized: "Close Tab"), image: UIImage(systemName: "xmark")) { [weak browser] _ in
                browser?.closeTab(active)
            })
        }
        return UIMenu(children: [UIMenu(options: .displayInline, children: tabs), UIMenu(options: .displayInline, children: actions)])
    }

    private func moreMenu(_ browser: LeoIOSAgentBrowser, control: LeoBrowserControl) -> UIMenu {
        let page = UIMenu(options: .displayInline, children: [
            UIAction(title: String(localized: "Find on Page"), image: UIImage(systemName: "magnifyingglass"),
                     attributes: browser.activeWebView == nil ? .disabled : []) { [weak browser] _ in
                browser?.activeWebView?.findInteraction?.presentFindNavigator(showingReplace: false)
            },
            UIAction(title: String(localized: "Copy URL"), image: UIImage(systemName: "doc.on.doc"),
                     attributes: Self.addressText(browser.activeURL).isEmpty ? .disabled : []) { [weak browser] _ in
                UIPasteboard.general.url = browser?.activeURL
            },
            UIAction(title: String(localized: "Open in Default Browser"), image: UIImage(systemName: "arrow.up.forward.app"),
                     attributes: browser.externalURL == nil ? .disabled : []) { [weak browser] _ in
                guard let url = browser?.externalURL else { return }
                UIApplication.shared.open(url)
            },
            UIAction(title: String(localized: "Reopen Closed Tab"), image: UIImage(systemName: "arrow.uturn.backward"),
                     attributes: browser.canReopenClosedTab ? [] : .disabled) { [weak browser] _ in
                browser?.reopenClosedTab()
            },
        ])
        var controlItems: [UIMenuElement] = []
        if control.isAgentDriving {
            controlItems.append(UIAction(title: String(localized: "Take Control"), image: UIImage(systemName: "person.fill")) { [weak self] _ in
                self?.store.send(.takeControlTapped)
            })
        }
        let clear = UIAction(
            title: String(localized: "Clear Site Data for This Agent…"), image: UIImage(systemName: "trash"),
            attributes: browser.isClearingSiteData ? [.destructive, .disabled] : .destructive
        ) { [weak self] _ in self?.confirmClearSiteData() }
        return UIMenu(children: [page, UIMenu(options: .displayInline, children: controlItems + [clear])])
    }

    /// D-887/D-888: names the agent and its machine; Cancel and a
    /// destructive Clear, neither of them the default.
    private func confirmClearSiteData() {
        let alert = UIAlertController(
            title: String(localized: "Clear site data for “\(store.displayName)” on \(store.machineName)?"),
            message: String(localized: "Removes cookies, caches and website storage from this agent’s browser. Other agents keep theirs. Open pages stay as they are until they reload."),
            preferredStyle: .alert
        )
        let browser = browser
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Clear Site Data"), style: .destructive) { [weak browser] _ in
            Task { await browser?.clearSiteData() }
        })
        alert.view.accessibilityIdentifier = "browser.clearSiteData"
        present(alert, animated: true)
    }

    // MARK: - UITextFieldDelegate

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        browser?.navigate(to: textField.text ?? "")
        textField.resignFirstResponder()
        return true
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        render()
    }
}
