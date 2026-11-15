import UIKit
import VisionKit

/// Live QR scanning with VisionKit. Reports the first QR payload once.
final class QRScannerViewController: UIViewController, DataScannerViewControllerDelegate {
    private let onScan: (String) -> Void
    private var didScan = false
    private lazy var scanner = DataScannerViewController(
        recognizedDataTypes: [.barcode(symbologies: [.qr])],
        qualityLevel: .balanced,
        recognizesMultipleItems: false,
        isHighFrameRateTrackingEnabled: false,
        isHighlightingEnabled: true
    )

    init(onScan: @escaping (String) -> Void) {
        self.onScan = onScan
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "Scan Pairing Code")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) }
        )
        scanner.delegate = self
        addChild(scanner)
        scanner.view.frame = view.bounds
        scanner.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scanner.view)
        scanner.didMove(toParent: self)

        let hint = UILabel()
        hint.text = String(localized: "Point the camera at the QR code from leo pair.")
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.textColor = .white
        hint.textAlignment = .center
        hint.numberOfLines = 0
        hint.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hint)
        NSLayoutConstraint.activate([
            hint.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            hint.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            hint.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard DataScannerViewController.isAvailable else {
            showUnavailable()
            return
        }
        try? scanner.startScanning()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        scanner.stopScanning()
    }

    func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
        for item in addedItems {
            guard !didScan, case .barcode(let barcode) = item, let payload = barcode.payloadStringValue else { continue }
            didScan = true
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            onScan(payload)
            return
        }
    }

    private func showUnavailable() {
        var configuration = UIContentUnavailableConfiguration.empty()
        configuration.image = UIImage(systemName: "camera.fill")
        configuration.text = String(localized: "Camera Unavailable")
        configuration.secondaryText = String(localized: "Allow camera access for Leo in Settings, or paste the pairing code instead.")
        contentUnavailableConfiguration = configuration
    }
}
