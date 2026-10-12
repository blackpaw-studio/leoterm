import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation

/// The thread's input bar: an attach menu (camera, photo library, Files),
/// a growing text view, and a send button that becomes a hold-to-record
/// mic when there is nothing to send. Dragging off the mic cancels.
final class ComposerView: UIView, UITextViewDelegate {
    enum Source { case camera, files, photos }

    /// How far a drag off the mic cancels the recording.
    private static let cancelDistance: CGFloat = 80
    private static let maximumTextHeight: CGFloat = 140

    private let store: StoreOf<Composer>
    private let pick: (Source) -> Void
    private let textView = UITextView()
    private let placeholder = UILabel()
    private let attachButton = UIButton(type: .system)
    private let actionButton = UIButton(type: .system)
    private let hintLabel = UILabel()
    private let chips = UIStackView()
    private let chipScroller = UIScrollView()
    private let recordingLabel = UILabel()
    private var textHeight: NSLayoutConstraint!
    private var recordingTimer: Timer?
    private var showsMic = true

    init(store: StoreOf<Composer>, pick: @escaping (Source) -> Void) {
        self.store = store
        self.pick = pick
        super.init(frame: .zero)
        backgroundColor = .systemBackground
        build()
        observe { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func build() {
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemBackground
        textView.layer.cornerRadius = 18
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
        textView.isScrollEnabled = false
        textView.delegate = self
        textView.accessibilityIdentifier = "chat.composer.text"
        placeholder.text = String(localized: "Message")
        placeholder.textColor = .placeholderText
        placeholder.font = textView.font
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)

        attachButton.setImage(UIImage(systemName: "plus.circle.fill", withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)), for: .normal)
        attachButton.accessibilityLabel = String(localized: "Attach")
        attachButton.showsMenuAsPrimaryAction = true
        attachButton.menu = UIMenu(children: [
            UIAction(title: String(localized: "Camera"), image: UIImage(systemName: "camera")) { [weak self] _ in self?.pick(.camera) },
            UIAction(title: String(localized: "Photo Library"), image: UIImage(systemName: "photo.on.rectangle")) { [weak self] _ in self?.pick(.photos) },
            UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")) { [weak self] _ in self?.pick(.files) },
        ])

        actionButton.addAction(UIAction { [weak self] _ in self?.actionTapped() }, for: .primaryActionTriggered)
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.15
        actionButton.addGestureRecognizer(hold)

        hintLabel.font = .preferredFont(forTextStyle: .footnote)
        hintLabel.textColor = .secondaryLabel
        hintLabel.numberOfLines = 0
        recordingLabel.font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .body).pointSize, weight: .medium)
        recordingLabel.textColor = .systemRed
        recordingLabel.isHidden = true

        chips.axis = .horizontal
        chips.spacing = 8
        chips.translatesAutoresizingMaskIntoConstraints = false
        chipScroller.showsHorizontalScrollIndicator = false
        chipScroller.addSubview(chips)

        let field = UIStackView(arrangedSubviews: [textView, recordingLabel])
        field.axis = .vertical
        let row = UIStackView(arrangedSubviews: [attachButton, field, actionButton])
        row.alignment = .bottom
        row.spacing = 8
        let column = UIStackView(arrangedSubviews: [hintLabel, chipScroller, row])
        column.axis = .vertical
        column.spacing = 6
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)

        textHeight = textView.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            column.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            column.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            textHeight,
            placeholder.leadingAnchor.constraint(equalTo: textView.leadingAnchor, constant: 15),
            placeholder.topAnchor.constraint(equalTo: textView.topAnchor, constant: 8),
            attachButton.widthAnchor.constraint(equalToConstant: 36),
            attachButton.heightAnchor.constraint(equalToConstant: 36),
            actionButton.widthAnchor.constraint(equalToConstant: 36),
            actionButton.heightAnchor.constraint(equalToConstant: 36),
            chipScroller.heightAnchor.constraint(equalToConstant: 34),
            chips.topAnchor.constraint(equalTo: chipScroller.contentLayoutGuide.topAnchor),
            chips.bottomAnchor.constraint(equalTo: chipScroller.contentLayoutGuide.bottomAnchor),
            chips.leadingAnchor.constraint(equalTo: chipScroller.contentLayoutGuide.leadingAnchor),
            chips.trailingAnchor.constraint(equalTo: chipScroller.contentLayoutGuide.trailingAnchor),
            chips.heightAnchor.constraint(equalTo: chipScroller.frameLayoutGuide.heightAnchor),
        ])
    }

    private func render() {
        if textView.text != store.text { textView.text = store.text; resizeText() }
        placeholder.isHidden = !store.text.isEmpty
        showsMic = store.outgoing == nil
        let symbol = store.isRecording ? "mic.circle.fill" : (showsMic ? "mic.circle" : "arrow.up.circle.fill")
        actionButton.setImage(UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 28)), for: .normal)
        actionButton.tintColor = store.isRecording ? .systemRed : .tintColor
        actionButton.isEnabled = !store.isSending
        actionButton.accessibilityLabel = showsMic ? String(localized: "Hold to record a voice note") : String(localized: "Send")
        actionButton.accessibilityIdentifier = showsMic ? "chat.composer.mic" : "chat.composer.send"
        attachButton.isEnabled = !store.isSending && !store.isRecording

        hintLabel.text = switch store.hint {
        case .failed(let reason): reason
        case .holdToRecord: String(localized: "Hold the mic to record a voice note.")
        case .microphoneDenied: String(localized: "Leo can't use the microphone. Allow it in Settings.")
        case nil: nil
        }
        hintLabel.isHidden = hintLabel.text == nil

        let attachments = store.attachments
        chipScroller.isHidden = attachments.isEmpty
        chips.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for file in attachments {
            var configuration = UIButton.Configuration.gray()
            configuration.title = file.filename
            configuration.image = UIImage(systemName: "xmark.circle.fill")
            configuration.imagePlacement = .trailing
            configuration.imagePadding = 4
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.titleLineBreakMode = .byTruncatingMiddle
            let chip = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
                self?.store.send(.removeAttachmentTapped(file.id))
            })
            chip.widthAnchor.constraint(lessThanOrEqualToConstant: 220).isActive = true
            chip.accessibilityLabel = String(localized: "Remove \(file.filename)")
            chips.addArrangedSubview(chip)
        }

        if case .recording(_, let startedAt) = store.recording {
            textView.isHidden = true
            recordingLabel.isHidden = false
            startTimer(from: startedAt)
        } else {
            textView.isHidden = false
            recordingLabel.isHidden = true
            recordingTimer?.invalidate()
            recordingTimer = nil
        }
    }

    private func startTimer(from start: Date) {
        guard recordingTimer == nil else { return }
        recordingStart = start
        updateRecordingLabel()
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateRecordingLabel() }
        }
    }

    private var recordingStart = Date()

    private func updateRecordingLabel() {
        let elapsed = Date().timeIntervalSince(recordingStart)
        recordingLabel.text = String(localized: "● \(ChatPresentation.duration(elapsed)) — slide away to cancel")
    }

    private func actionTapped() {
        if showsMic {
            store.send(.micTapped)
        } else {
            store.send(.sendButtonTapped)
        }
    }

    @objc private func held(_ recognizer: UILongPressGestureRecognizer) {
        guard showsMic || store.isRecording else { return }
        switch recognizer.state {
        case .began:
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            store.send(.recordButtonPressed)
        case .changed:
            let point = recognizer.location(in: actionButton)
            if hypot(point.x - actionButton.bounds.midX, point.y - actionButton.bounds.midY) > Self.cancelDistance {
                recognizer.state = .cancelled
            }
        case .ended:
            store.send(.recordButtonReleased)
        case .cancelled, .failed:
            store.send(.recordButtonCancelled)
        default:
            break
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        store.send(.binding(.set(\.text, textView.text)))
        resizeText()
    }

    private func resizeText() {
        let fitting = textView.sizeThatFits(CGSize(width: textView.bounds.width, height: .greatestFiniteMagnitude)).height
        textView.isScrollEnabled = fitting > Self.maximumTextHeight
        textHeight.constant = min(max(fitting, 36), Self.maximumTextHeight)
    }

    func focus() { textView.becomeFirstResponder() }
}
