import AVFoundation
import ComposableArchitecture
import LeoFeatures
import LeoKit
import PhotosUI
import UIKit
import UIKitNavigation
import UniformTypeIdentifiers

/// One agent's thread: messages oldest to newest (older pages load when
/// scrolled to the top), a task filter menu, and the composer pinned above
/// the keyboard.
final class ChatThreadViewController: UIViewController, UICollectionViewDelegate {
    /// How close to the top (in points) loads the older page.
    private static let olderPageThreshold: CGFloat = 300
    /// Room kept around a focused ask field when it scrolls into view.
    private static let focusedFieldMargin: CGFloat = 16

    @UIBindable private var store: StoreOf<ChatThread>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var composer = ComposerView(store: store.scope(state: \.composer, action: \.composer)) { [weak self] in self?.pick($0) }
    private let replyBanner = UIButton(configuration: .plain())
    private let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"))
    private let terminalButton = UIBarButtonItem(image: UIImage(systemName: "terminal"))
    private let infoButton = UIBarButtonItem(image: UIImage(systemName: "info.circle"))
    private let titleView = ChatThreadTitleView()
    private let voice = VoicePlayer()
    private var shownIDs: [String] = []
    private var shownItems: [String: LeoChatTranscript.Item] = [:]
    /// The gap above each shown item (`LeoChatTranscript.spacing`).
    private var shownSpacing: [String: CGFloat] = [:]
    private var pendingPlay: String?
    private var settleReveal = SettleReveal()

    init(store: StoreOf<ChatThread>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.titleView = titleView
        navigationItem.rightBarButtonItems = [infoButton, terminalButton, filterButton]
        filterButton.accessibilityLabel = String(localized: "Filter Task Output")
        terminalButton.accessibilityLabel = String(localized: "Terminal")
        terminalButton.accessibilityIdentifier = "chat.terminal"
        terminalButton.primaryAction = UIAction(image: terminalButton.image) { [weak self] _ in self?.store.send(.terminalButtonTapped) }
        infoButton.accessibilityLabel = String(localized: "Agent Info")
        infoButton.accessibilityIdentifier = "chat.info"
        infoButton.primaryAction = UIAction(image: infoButton.image) { [weak self] _ in self?.store.send(.infoButtonTapped) }
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.accessibilityIdentifier = "chat.thread"
        voice.onChange = { [weak self] in self?.reconfigureAll() }

        var banner = UIButton.Configuration.gray()
        banner.image = UIImage(systemName: "xmark.circle.fill")
        banner.imagePlacement = .trailing
        banner.imagePadding = 6
        banner.cornerStyle = .capsule
        banner.buttonSize = .small
        replyBanner.configuration = banner
        replyBanner.addAction(UIAction { [weak self] _ in self?.store.send(.replyCancelled) }, for: .primaryActionTriggered)

        let bottom = UIStackView(arrangedSubviews: [replyBanner, composer])
        bottom.axis = .vertical
        bottom.alignment = .fill
        bottom.spacing = 0
        for subview in [collectionView, bottom] as [UIView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottom.topAnchor),
            bottom.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottom.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottom.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
        configureDataSource()
        // An ask's text field sits in the thread, not the composer: once the
        // keyboard is up, bring the field above it.
        NotificationCenter.default.addObserver(self, selector: #selector(revealFocusedAskField), name: UIResponder.keyboardDidShowNotification, object: nil)
        // "Today" in a time header goes stale at midnight or on a clock or zone change.
        NotificationCenter.default.addObserver(self, selector: #selector(reconfigureTimeHeaders), name: UIApplication.significantTimeChangeNotification, object: nil)

        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
        }
        navigationDestination(item: $store.scope(state: \.terminal, action: \.terminal)) { store in
            TerminalViewController(store: store)
        }
        observe { [weak self] in self?.render() }
        store.send(.task)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        store.send(.onScreenChanged(true))
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        store.send(.onScreenChanged(false))
        voice.stop()
    }

    private func makeLayout() -> UICollectionViewLayout {
        let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
        let section = NSCollectionLayoutSection(group: .vertical(layoutSize: size, subitems: [NSCollectionLayoutItem(layoutSize: size)]))
        section.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0)
        return UICollectionViewCompositionalLayout(section: section)
    }

    private func configureDataSource() {
        let messageCell = UICollectionView.CellRegistration<ChatMessageCell, String> { [weak self] cell, _, id in
            guard let self, case .message(let message, let position)? = shownItems[id] else { return }
            let model = ChatMessageCell.Model(
                message: message, isAnswering: store.answering.contains(id),
                draft: store.askDrafts[id] ?? LeoChatAskDraft(), questionsDraft: store.questionsDrafts[id],
                questionsError: store.questionsErrors[id], position: position, topSpacing: shownSpacing[id] ?? 0,
                files: store.attachmentFiles, playingAttachmentID: voice.playingID
            )
            cell.configure(model) { [weak self] event in self?.handle(event, message: message) }
        }
        let headerCell = UICollectionView.CellRegistration<ChatTimeHeaderCell, String> { [weak self] cell, _, id in
            guard let self, case .timeHeader(let date, _)? = shownItems[id] else { return }
            cell.configure(date: date, id: id, topSpacing: shownSpacing[id] ?? 0)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { [weak self] collectionView, indexPath, id in
            if case .timeHeader? = self?.shownItems[id] {
                return collectionView.dequeueConfiguredReusableCell(using: headerCell, for: indexPath, item: id)
            }
            return collectionView.dequeueConfiguredReusableCell(using: messageCell, for: indexPath, item: id)
        }
    }

    private func render() {
        title = store.agentName
        titleView.configure(agentName: store.agentName, agent: store.agent, daemonName: store.daemon.name)
        renderFilterMenu()
        renderReplyBanner()

        let items = LeoChatTranscript.items(for: Array(store.messages))
        let ids = items.map(\.id)
        let newItems = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let changed = ids.filter { shownItems[$0] != newItems[$0] }
        let wasAtBottom = isNearBottom
        let prepended = !shownIDs.isEmpty && ids.count > shownIDs.count && ids.last == shownIDs.last
        let previousHeight = collectionView.contentSize.height
        shownItems = newItems
        shownSpacing = Dictionary(uniqueKeysWithValues: items.enumerated().map { index, item in
            (item.id, LeoChatTranscript.spacing(above: item, after: index > 0 ? items[index - 1] : nil))
        })

        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(ids)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { changed.contains($0) || shownIDs.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        let isFirstFill = shownIDs.isEmpty && !ids.isEmpty
        shownIDs = ids

        collectionView.layoutIfNeeded()
        if prepended {
            // Keep the reader's place when an older page lands on top.
            collectionView.contentOffset.y += collectionView.contentSize.height - previousHeight
        } else if isFirstFill || wasAtBottom {
            scrollToBottom()
        }
        revealSettledQuestionCards()
        if let id = pendingPlay, case .loaded(let url) = store.attachmentFiles[id] {
            pendingPlay = nil
            voice.toggle(id: id, url: url)
        }
        renderEmptyState()
    }

    private func renderEmptyState() {
        if store.messages.isEmpty, store.isLoading {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else if store.messages.isEmpty, let error = store.loadError {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "exclamationmark.bubble")
            configuration.text = String(localized: "Couldn't Load Messages")
            configuration.secondaryText = error
            var button = UIButton.Configuration.bordered()
            button.title = String(localized: "Try Again")
            configuration.button = button
            configuration.buttonProperties.primaryAction = UIAction { [weak self] _ in self?.store.send(.retryButtonTapped) }
            contentUnavailableConfiguration = configuration
        } else if store.messages.isEmpty {
            var configuration = UIContentUnavailableConfiguration.empty()
            configuration.image = UIImage(systemName: "bubble.left.and.bubble.right")
            configuration.text = store.taskFilter == nil ? String(localized: "No Messages Yet") : String(localized: "No Output from \(store.taskFilter ?? "")")
            configuration.secondaryText = store.taskFilter == nil ? String(localized: "Say hello to \(store.agentName).") : nil
            contentUnavailableConfiguration = configuration
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func renderFilterMenu() {
        let current = store.taskFilter
        let all = UIAction(title: String(localized: "All Messages"), state: current == nil ? .on : .off) { [weak self] _ in
            self?.store.send(.taskFilterChanged(nil))
        }
        let tasks = store.knownTasks.sorted().map { task in
            UIAction(title: task, image: UIImage(systemName: "clock.arrow.circlepath"), state: current == task ? .on : .off) { [weak self] _ in
                self?.store.send(.taskFilterChanged(task))
            }
        }
        filterButton.menu = UIMenu(title: String(localized: "Task Output"), children: [all] + (tasks.isEmpty ? [] : [UIMenu(options: .displayInline, children: tasks)]))
        filterButton.image = UIImage(systemName: current == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        filterButton.isEnabled = !store.knownTasks.isEmpty || current != nil
    }

    private func renderReplyBanner() {
        guard let id = store.replyTo, let message = store.messages[id: id] else {
            replyBanner.isHidden = true
            return
        }
        replyBanner.isHidden = false
        replyBanner.configuration?.title = String(localized: "Replying to \(message.task ?? ChatPresentation.preview(message))")
        replyBanner.configuration?.titleLineBreakMode = .byTruncatingTail
    }

    /// A questions card the user just submitted or dismissed is much shorter
    /// once settled, which can leave it above the screen: bring its top back
    /// into view. A card that settles on its own leaves the scroll alone.
    private func revealSettledQuestionCards() {
        guard let id = settleReveal.settled(in: store.messages, answering: store.answering),
              let indexPath = dataSource.indexPath(for: id),
              let frame = collectionView.layoutAttributesForItem(at: indexPath)?.frame else { return }
        let inset = collectionView.adjustedContentInset
        guard frame.minY < collectionView.contentOffset.y + inset.top else { return }
        let lowest = collectionView.contentSize.height - collectionView.bounds.height + inset.bottom
        let top = min(frame.minY - inset.top - Self.focusedFieldMargin, lowest)
        collectionView.setContentOffset(CGPoint(x: 0, y: max(top, -inset.top)), animated: true)
    }

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return collectionView.contentSize.height - visibleBottom < 80
    }

    private func scrollToBottom() {
        guard let last = shownIDs.last, let indexPath = dataSource.indexPath(for: last) else { return }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
    }

    @objc private func revealFocusedAskField() {
        let cells = collectionView.visibleCells.compactMap { $0 as? ChatMessageCell }
        guard let frame = cells.lazy.compactMap({ $0.focusedTextFrame(in: self.collectionView) }).first else { return }
        collectionView.scrollRectToVisible(frame.insetBy(dx: 0, dy: -Self.focusedFieldMargin), animated: true)
    }

    @objc private func reconfigureTimeHeaders() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { if case .timeHeader? = shownItems[$0] { true } else { false } })
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func reconfigureAll() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func handle(_ event: ChatMessageCell.Event, message: LeoChatMessage) {
        switch event {
        case .choice(let value):
            store.send(.askChoiceTapped(messageID: message.id, value: value))
        case .text(let text):
            store.send(.askTextChanged(messageID: message.id, text))
        case .submit:
            store.send(.askSubmitTapped(messageID: message.id))
        case .replyInstead:
            composer.focus()
        case .questionChoice, .questionText, .questionsSubmit, .questionsDismiss:
            if event.settlesCard { settleReveal.acted(on: message.id) }
            event.questionsAction(messageID: message.id).map { store.send($0) }
        case .openAttachment(let attachment):
            open(attachment)
        case .playVoice(let attachment):
            if case .loaded(let url) = store.attachmentFiles[attachment.id] {
                voice.toggle(id: attachment.id, url: url)
            } else {
                pendingPlay = attachment.id
                store.send(.attachmentNeeded(attachment))
            }
        case .reply:
            store.send(.replyTapped(message.id))
            composer.focus()
        }
    }

    private func open(_ attachment: LeoChatAttachment) {
        guard case .loaded(let url) = store.attachmentFiles[attachment.id] else {
            store.send(.attachmentNeeded(attachment))
            if case .failed(let reason) = store.attachmentFiles[attachment.id] {
                let alert = UIAlertController(title: String(localized: "Couldn't Open \(attachment.filename)"), message: reason, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
                present(alert, animated: true)
            }
            return
        }
        let preview = ChatQuickLookController(url: url, title: attachment.filename)
        present(preview, animated: true)
    }

    // MARK: UICollectionViewDelegate

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), case .message(let message, _)? = shownItems[id] else { return }
        // Images show inline, so they load as they scroll into view.
        for attachment in message.attachments where attachment.isImage && attachment.available && store.attachmentFiles[attachment.id] == nil {
            store.send(.attachmentNeeded(attachment))
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool { false }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView.isDragging || scrollView.isDecelerating, scrollView.contentOffset.y < Self.olderPageThreshold else { return }
        if store.hasMore, !store.isLoadingOlder { store.send(.loadOlderTriggered) }
    }

    // MARK: Picking attachments

    private func pick(_ source: ComposerView.Source) {
        switch source {
        case .camera:
            guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
            let picker = UIImagePickerController()
            picker.sourceType = .camera
            picker.delegate = pickerDelegate
            present(picker, animated: true)
        case .photos:
            var configuration = PHPickerConfiguration()
            configuration.filter = .images
            configuration.selectionLimit = 10
            let picker = PHPickerViewController(configuration: configuration)
            picker.delegate = pickerDelegate
            present(picker, animated: true)
        case .files:
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
            picker.allowsMultipleSelection = true
            picker.delegate = pickerDelegate
            present(picker, animated: true)
        }
    }

    private lazy var pickerDelegate = AttachmentPickerDelegate { [weak self] file in
        self?.store.send(.composer(.attachmentPicked(file)))
    }
}

/// Plays one voice note at a time.
@MainActor
final class VoicePlayer: NSObject, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private(set) var playingID: String?
    var onChange: () -> Void = {}

    func toggle(id: String, url: URL) {
        if playingID == id {
            stop()
            return
        }
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
            try AVAudioSession.sharedInstance().setActive(true)
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.play()
            self.player = player
            playingID = id
        } catch {
            playingID = nil
        }
        onChange()
    }

    func stop() {
        guard player != nil else { return }
        player?.stop()
        player = nil
        playingID = nil
        onChange()
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { stop() }
    }
}
