import ComposableArchitecture
import LeoFeatures
import UIKit
import UIKitNavigation
import VisionKit

/// Pair with a daemon: scan the QR code `leo pair` prints, or paste the
/// JSON line under it.
final class PairingViewController: UIViewController, UITextViewDelegate {
    @UIBindable private var store: StoreOf<Pairing>
    private let scrollView = UIScrollView()
    private let payloadView = UITextView()
    private let placeholder = UILabel()
    private let errorLabel = UILabel()
    private let errorRow = UIStackView()
    private lazy var pairButton = UIBarButtonItem(
        title: String(localized: "Pair"), style: .prominent, target: self, action: #selector(pairTapped)
    )
    private let spinner = UIActivityIndicatorView(style: .medium)

    init(store: StoreOf<Pairing>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Pair Daemon")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private var canScan: Bool { DataScannerViewController.isSupported }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemGroupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.store.send(.cancelButtonTapped) }
        )
        pairButton.accessibilityIdentifier = "pairing.pair"
        navigationItem.rightBarButtonItem = pairButton
        isModalInPresentation = true
        layout()

        present(isPresented: $store.isScannerPresented) { [weak self] in
            UINavigationController(rootViewController: QRScannerViewController { code in
                self?.store.send(.codeScanned(code))
            })
        }

        observe { [weak self] in
            guard let self else { return }
            if payloadView.text != store.payloadText { payloadView.text = store.payloadText }
            placeholder.isHidden = !store.payloadText.isEmpty
            errorLabel.text = store.errorMessage
            errorRow.isHidden = store.errorMessage == nil
            pairButton.isEnabled = store.canPair
            payloadView.isEditable = !store.isPairing
            if store.isPairing {
                spinner.startAnimating()
                navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
            } else {
                spinner.stopAnimating()
                navigationItem.rightBarButtonItem = pairButton
            }
        }
    }

    @objc private func pairTapped() {
        view.endEditing(true)
        store.send(.pairButtonTapped)
    }

    func textViewDidChange(_ textView: UITextView) {
        store.payloadText = textView.text
    }

    // MARK: Layout

    private func layout() {
        scrollView.keyboardDismissMode = .interactive
        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -20),
        ])

        stack.addArrangedSubview(hero())
        stack.setCustomSpacing(24, after: stack.arrangedSubviews.last!)
        if canScan {
            var scan = UIButton.Configuration.prominentGlass()
            scan.title = String(localized: "Scan QR Code")
            scan.image = UIImage(systemName: "qrcode.viewfinder")
            scan.imagePadding = 8
            scan.buttonSize = .large
            let button = UIButton(configuration: scan, primaryAction: UIAction { [weak self] _ in self?.store.send(.scanButtonTapped) })
            stack.addArrangedSubview(button)
            stack.setCustomSpacing(28, after: button)
        }

        stack.addArrangedSubview(sectionLabel(canScan ? String(localized: "Or Paste the Pairing Code") : String(localized: "Pairing Code")))
        stack.addArrangedSubview(payloadCard())
        errorRow.isHidden = true
        stack.addArrangedSubview(errorRow)
        configureErrorRow()
        stack.setCustomSpacing(28, after: errorRow)

        stack.addArrangedSubview(sectionLabel(String(localized: "Cloudflare Access (Optional)")))
        stack.addArrangedSubview(accessCard())
        stack.addArrangedSubview(footnote(String(localized: "Only needed when the daemon is behind Cloudflare Access. The service token is stored in the Keychain with this device's token.")))
    }

    private func hero() -> UIView {
        let icon = UIImageView(image: UIImage(systemName: "qrcode"))
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        icon.tintColor = .tintColor
        icon.contentMode = .scaleAspectFit
        let title = UILabel()
        title.text = String(localized: "Pair with a Leo Daemon")
        title.font = .preferredFont(forTextStyle: .title2).withWeight(.bold)
        title.adjustsFontForContentSizeCategory = true
        title.textAlignment = .center
        let body = UILabel()
        body.text = String(localized: "On the machine running Leo, run leo pair. It shows a QR code and a one-line pairing code that works once for five minutes.")
        body.font = .preferredFont(forTextStyle: .subheadline)
        body.adjustsFontForContentSizeCategory = true
        body.textColor = .secondaryLabel
        body.textAlignment = .center
        body.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [icon, title, body])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 8
        stack.setCustomSpacing(12, after: icon)
        return stack
    }

    private func payloadCard() -> UIView {
        payloadView.delegate = self
        payloadView.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        payloadView.adjustsFontForContentSizeCategory = true
        payloadView.backgroundColor = .clear
        payloadView.autocorrectionType = .no
        payloadView.autocapitalizationType = .none
        payloadView.smartQuotesType = .no
        payloadView.smartDashesType = .no
        payloadView.spellCheckingType = .no
        payloadView.textContainerInset = UIEdgeInsets(top: 12, left: 8, bottom: 12, right: 8)
        payloadView.accessibilityIdentifier = "pairing.payload"
        payloadView.accessibilityLabel = String(localized: "Pairing code")
        payloadView.translatesAutoresizingMaskIntoConstraints = false
        payloadView.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true

        placeholder.text = #"{"daemon_id": …, "pairing_code": …}"#
        placeholder.font = payloadView.font
        placeholder.textColor = .placeholderText
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        payloadView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.topAnchor.constraint(equalTo: payloadView.topAnchor, constant: 12),
            placeholder.leadingAnchor.constraint(equalTo: payloadView.leadingAnchor, constant: 13),
        ])

        let paste = UIPasteControl(configuration: {
            let configuration = UIPasteControl.Configuration()
            configuration.displayMode = .iconAndLabel
            configuration.cornerStyle = .capsule
            return configuration
        }())
        paste.target = payloadView
        let pasteRow = UIStackView(arrangedSubviews: [UIView(), paste])
        pasteRow.isLayoutMarginsRelativeArrangement = true
        pasteRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 12, trailing: 12)

        let card = UIStackView(arrangedSubviews: [payloadView, pasteRow])
        card.axis = .vertical
        return cardBackground(card)
    }

    private func accessCard() -> UIView {
        let clientID = UITextField(text: $store.cfClientID)
        clientID.placeholder = String(localized: "Client ID")
        clientID.accessibilityIdentifier = "pairing.cfClientID"
        let secret = UITextField(text: $store.cfClientSecret)
        secret.placeholder = String(localized: "Client Secret")
        secret.isSecureTextEntry = true
        secret.textContentType = .password
        secret.accessibilityIdentifier = "pairing.cfClientSecret"
        for field in [clientID, secret] {
            field.autocorrectionType = .no
            field.autocapitalizationType = .none
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        }
        let separator = UIView()
        separator.backgroundColor = .separator
        separator.heightAnchor.constraint(equalToConstant: 1 / max(traitCollection.displayScale, 1)).isActive = true
        let stack = UIStackView(arrangedSubviews: [clientID, separator, secret])
        stack.axis = .vertical
        stack.isLayoutMarginsRelativeArrangement = true
        stack.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16)
        return cardBackground(stack)
    }

    private func configureErrorRow() {
        let icon = UIImageView(image: UIImage(systemName: "exclamationmark.triangle.fill"))
        icon.tintColor = .systemRed
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .footnote)
        errorLabel.font = .preferredFont(forTextStyle: .footnote)
        errorLabel.adjustsFontForContentSizeCategory = true
        errorLabel.textColor = .systemRed
        errorLabel.numberOfLines = 0
        errorLabel.accessibilityIdentifier = "pairing.error"
        errorRow.addArrangedSubview(icon)
        errorRow.addArrangedSubview(errorLabel)
        errorRow.spacing = 6
        errorRow.alignment = .firstBaseline
        errorRow.isLayoutMarginsRelativeArrangement = true
        errorRow.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 4, leading: 16, bottom: 0, trailing: 16)
    }

    private func cardBackground(_ content: UIView) -> UIView {
        let card = UIView()
        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 26
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        content.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: card.topAnchor),
            content.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: card.trailingAnchor),
        ])
        return card
    }

    private func sectionLabel(_ text: String) -> UIView {
        var content = UIListContentConfiguration.header()
        content.text = text
        content.directionalLayoutMargins.leading = 16
        content.directionalLayoutMargins.bottom = 0
        return UIListContentView(configuration: content)
    }

    private func footnote(_ text: String) -> UIView {
        var content = UIListContentConfiguration.footer()
        content.text = text
        content.directionalLayoutMargins.leading = 16
        content.directionalLayoutMargins.trailing = 16
        return UIListContentView(configuration: content)
    }
}
