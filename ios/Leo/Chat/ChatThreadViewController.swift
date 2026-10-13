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

    @UIBindable private var store: StoreOf<ChatThread>
    private lazy var collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!
    private lazy var composer = ComposerView(store: store.scope(state: \.composer, action: \.composer)) { [weak self] in self?.pick($0) }
    private let replyBanner = UIButton(configuration: .plain())
    private let filterButton = UIBarButtonItem(image: UIImage(systemName: "line.3.horizontal.decrease.circle"))
    private let voice = VoicePlayer()
    private var shownIDs: [String] = []
    private var shownMessages: [String: LeoChatMessage] = [:]
    private var pendingPlay: String?

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
        navigationItem.rightBarButtonItem = filterButton
        filterButton.accessibilityLabel = String(localized: "Filter Task Output")
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
            bottom.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        configureDataSource()

        present(item: $store.scope(state: \.alert, action: \.alert)) { store in
            UIAlertController(store: store)
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
        let registration = UICollectionView.CellRegistration<ChatMessageCell, String> { [weak self] cell, _, id in
            guard let self, let message = shownMessages[id] else { return }
            let previous = store.messages.index(id: id).flatMap { $0 > 0 ? store.messages[$0 - 1] : nil }
            let model = ChatMessageCell.Model(
                message: message, isExpanded: store.expanded.contains(id), isAnswering: store.answering.contains(id),
                draft: store.askDrafts[id] ?? LeoChatAskDraft(), continuesPost: message.continuesPost(after: previous),
                files: store.attachmentFiles, playingAttachmentID: voice.playingID
            )
            cell.configure(model) { [weak self] event in self?.handle(event, message: message) }
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: registration, for: indexPath, item: id)
        }
    }

    private func render() {
        title = store.agentName
        navigationItem.subtitle = store.agent.map(\.statusText)
        renderFilterMenu()
        renderReplyBanner()

        let messages = store.messages
        let ids = messages.ids.elements
        let changed = ids.filter { shownMessages[$0] != messages[id: $0] }
        let wasAtBottom = isNearBottom
        let prepended = !shownIDs.isEmpty && ids.count > shownIDs.count && ids.last == shownIDs.last
        let previousHeight = collectionView.contentSize.height
        shownMessages = Dictionary(uniqueKeysWithValues: messages.map { ($0.id, $0) })

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

    private var isNearBottom: Bool {
        let visibleBottom = collectionView.contentOffset.y + collectionView.bounds.height - collectionView.adjustedContentInset.bottom
        return collectionView.contentSize.height - visibleBottom < 80
    }

    private func scrollToBottom() {
        guard let last = shownIDs.last, let indexPath = dataSource.indexPath(for: last) else { return }
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: false)
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
        case .expand:
            store.send(.expandToggled(message.id))
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
        guard let id = dataSource.itemIdentifier(for: indexPath), let message = shownMessages[id] else { return }
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
