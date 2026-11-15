import ImageIO
import LeoFeatures
import LeoKit
import UIKit

/// One image of the full-screen viewer: the whole original, aspect-fit and never
/// cropped, that pinch and double-tap zoom. While the file loads it shows a
/// spinner; if loading failed, the reason and a way to try again.
final class ChatImagePageController: UIViewController, UIScrollViewDelegate {
    typealias File = ChatThread.AttachmentFile

    /// The longest side decoded, so a huge original can't exhaust memory. The
    /// image is still whole; only its pixel count is bounded.
    static let maxDecodedSide = 4_096
    private static let maxZoom: CGFloat = 4
    private static let doubleTapZoom: CGFloat = 2.5

    let attachment: LeoChatAttachment
    let index: Int
    let scrollView = UIScrollView()
    let imageView = UIImageView()
    let spinner = UIActivityIndicatorView(style: .large)
    let failureLabel = UILabel()
    let retryButton = UIButton(configuration: .bordered())
    private let file: (String) -> File
    private let need: (LeoChatAttachment) -> Void
    private var shownURL: URL?

    init(attachment: LeoChatAttachment, index: Int, file: @escaping (String) -> File, need: @escaping (LeoChatAttachment) -> Void) {
        self.attachment = attachment
        self.index = index
        self.file = file
        self.need = need
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Whether the picture is at rest, so a drag down means "dismiss" rather than "pan".
    var isZoomedOut: Bool { scrollView.zoomScale <= scrollView.minimumZoomScale + 0.01 }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        scrollView.delegate = self
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = Self.maxZoom
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(scrollView)

        imageView.contentMode = .scaleAspectFit
        imageView.isAccessibilityElement = true
        imageView.accessibilityLabel = attachment.filename
        imageView.accessibilityIdentifier = "chat.imageViewer.image.\(attachment.id)"
        scrollView.addSubview(imageView)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)

        spinner.color = .white
        failureLabel.textColor = .white
        failureLabel.font = .preferredFont(forTextStyle: .body)
        failureLabel.adjustsFontForContentSizeCategory = true
        failureLabel.numberOfLines = 0
        failureLabel.textAlignment = .center
        var retry = UIButton.Configuration.bordered()
        retry.title = String(localized: "Try Again")
        retry.baseForegroundColor = .white
        retryButton.configuration = retry
        retryButton.accessibilityIdentifier = "chat.imageViewer.retry"
        retryButton.addAction(UIAction { [weak self] _ in self.map { $0.need($0.attachment) } }, for: .primaryActionTriggered)

        let status = UIStackView(arrangedSubviews: [spinner, failureLabel, retryButton])
        status.axis = .vertical
        status.alignment = .center
        status.spacing = 16
        status.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            status.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            status.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            status.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
        refresh()
        if case .loading = file(attachment.id) { need(attachment) }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isZoomedOut else { return }
        // The view fills the page and the image fits inside it, so a rotation or a resize only re-fits.
        imageView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
        scrollView.contentSize = scrollView.bounds.size
    }

    /// Redraws from the current file state; the image decodes once per file.
    func refresh() {
        guard isViewLoaded else { return }
        switch file(attachment.id) {
        case .loaded(let url):
            if shownURL != url {
                imageView.image = Self.decode(url)
                shownURL = url
            }
            let isDecoded = imageView.image != nil
            spinner.stopAnimating()
            failureLabel.isHidden = isDecoded
            failureLabel.text = String(localized: "Couldn't Open \(attachment.filename)")
            retryButton.isHidden = true
        case .loading:
            spinner.startAnimating()
            failureLabel.isHidden = true
            retryButton.isHidden = true
        case .failed(let reason):
            spinner.stopAnimating()
            failureLabel.isHidden = false
            failureLabel.text = String(localized: "Couldn't Load \(attachment.filename)\n\(reason)")
            retryButton.isHidden = false
        }
    }

    /// The upright image at `url`, whole, with its longest side capped at `maxDecodedSide`.
    static func decode(_ url: URL) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDecodedSide
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }

    @objc private func doubleTapped(_ recognizer: UITapGestureRecognizer) {
        guard imageView.image != nil else { return }
        guard isZoomedOut else {
            scrollView.setZoomScale(scrollView.minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let size = CGSize(width: scrollView.bounds.width / Self.doubleTapZoom, height: scrollView.bounds.height / Self.doubleTapZoom)
        scrollView.zoom(to: CGRect(origin: CGPoint(x: point.x - size.width / 2, y: point.y - size.height / 2), size: size), animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // Keep a picture smaller than the page centered while it zooms.
        let inset = CGSize(
            width: max(0, (scrollView.bounds.width - scrollView.contentSize.width) / 2),
            height: max(0, (scrollView.bounds.height - scrollView.contentSize.height) / 2)
        )
        scrollView.contentInset = UIEdgeInsets(top: inset.height, left: inset.width, bottom: inset.height, right: inset.width)
    }
}
