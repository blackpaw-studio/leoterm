import LeoFeatures
import LeoKit
import UIKit

/// The full-screen image viewer: opens at the tapped image of a message and
/// pages through all of that message's images ("2 of 4"). Dismiss with the close
/// button or by dragging down. It holds no state of its own: files come from
/// the thread through `file`, and `need` asks the thread to load one.
///
/// It presents `.overFullScreen`, so the chat underneath is never taken off
/// screen: it keeps counting as viewed, and no badge builds up behind the viewer.
final class ChatImageViewerController: UIViewController, UIPageViewControllerDataSource, UIPageViewControllerDelegate, UIGestureRecognizerDelegate {
    typealias File = ChatThread.AttachmentFile

    /// A drag down this far, or this fast (points per second), dismisses.
    private static let dismissDistance: CGFloat = 100
    private static let dismissVelocity: CGFloat = 800
    private static let pageSpacing: CGFloat = 16
    private static let controlMargin: CGFloat = 12

    let pageController = UIPageViewController(
        transitionStyle: .scroll, navigationOrientation: .horizontal,
        options: [.interPageSpacing: ChatImageViewerController.pageSpacing]
    )
    let positionLabel = PositionLabel()
    let closeButton = UIButton(configuration: .glass())
    private let gallery: LeoChatImageGallery
    private let file: (String) -> File
    private let need: (LeoChatAttachment) -> Void
    private let livePages = NSHashTable<ChatImagePageController>.weakObjects()

    init(gallery: LeoChatImageGallery, file: @escaping (String) -> File, need: @escaping (LeoChatAttachment) -> Void) {
        self.gallery = gallery
        self.file = file
        self.need = need
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
        overrideUserInterfaceStyle = .dark
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Presents a viewer over `host` without taking `host` off screen.
    @discardableResult
    static func present(
        from host: UIViewController, gallery: LeoChatImageGallery, file: @escaping (String) -> File,
        need: @escaping (LeoChatAttachment) -> Void, animated: Bool = true
    ) -> ChatImageViewerController {
        let viewer = ChatImageViewerController(gallery: gallery, file: file, need: need)
        host.present(viewer, animated: animated)
        return viewer
    }

    /// Whether a drag of `offset` points down, still moving at `velocity`, lets go of the viewer.
    static func shouldDismiss(offset: CGFloat, velocity: CGFloat) -> Bool {
        offset > dismissDistance || velocity > dismissVelocity
    }

    var currentPage: ChatImagePageController? { pageController.viewControllers?.first as? ChatImagePageController }

    override var prefersStatusBarHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        pageController.dataSource = gallery.images.count > 1 ? self : nil
        pageController.delegate = self
        addChild(pageController)
        pageController.view.frame = view.bounds
        pageController.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(pageController.view)
        pageController.didMove(toParent: self)
        pageController.setViewControllers([makePage(gallery.startIndex)], direction: .forward, animated: false)

        var close = closeButton.configuration ?? .glass()
        close.image = UIImage(systemName: "xmark")
        closeButton.configuration = close
        closeButton.accessibilityLabel = String(localized: "Close")
        closeButton.accessibilityIdentifier = "chat.imageViewer.close"
        closeButton.addAction(UIAction { [weak self] _ in self?.dismiss(animated: true) }, for: .primaryActionTriggered)
        positionLabel.accessibilityIdentifier = "chat.imageViewer.position"
        positionLabel.isHidden = gallery.images.count < 2
        for control in [closeButton, positionLabel] as [UIView] {
            control.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(control)
        }
        NSLayoutConstraint.activate([
            closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Self.controlMargin),
            closeButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Self.controlMargin),
            positionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            positionLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor)
        ])
        updatePosition(gallery.startIndex)

        let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
        drag.delegate = self
        view.addGestureRecognizer(drag)
    }

    /// Redraws every page from the thread's current file state, so an image
    /// that finishes loading appears in place.
    func refresh() {
        livePages.allObjects.forEach { $0.refresh() }
    }

    /// Points the "2 of 4" label at `page`.
    func didShow(_ page: ChatImagePageController) {
        updatePosition(page.index)
    }

    private func updatePosition(_ index: Int) {
        positionLabel.text = String(localized: "\(index + 1) of \(gallery.images.count)")
    }

    private func makePage(_ index: Int) -> ChatImagePageController {
        let page = ChatImagePageController(attachment: gallery.images[index], index: index, file: file, need: need)
        livePages.add(page)
        return page
    }

    // MARK: UIPageViewControllerDataSource

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ChatImagePageController, page.index > 0 else { return nil }
        return makePage(page.index - 1)
    }

    func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
        guard let page = viewController as? ChatImagePageController, page.index < gallery.images.count - 1 else { return nil }
        return makePage(page.index + 1)
    }

    // MARK: UIPageViewControllerDelegate

    func pageViewController(
        _ pageViewController: UIPageViewController, didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController], transitionCompleted completed: Bool
    ) {
        guard completed, let page = currentPage else { return }
        didShow(page)
    }

    // MARK: Drag down to dismiss

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let pan = gestureRecognizer as? UIPanGestureRecognizer, currentPage?.isZoomedOut ?? true else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.y > 0 && abs(velocity.y) > abs(velocity.x)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func dragged(_ pan: UIPanGestureRecognizer) {
        let offset = max(0, pan.translation(in: view).y)
        switch pan.state {
        case .changed:
            pageController.view.transform = CGAffineTransform(translationX: 0, y: offset)
            view.backgroundColor = UIColor.black.withAlphaComponent(1 - min(0.7, offset / (view.bounds.height * 0.6)))
            [closeButton, positionLabel].forEach { $0.alpha = 0 }
        case .ended where Self.shouldDismiss(offset: offset, velocity: pan.velocity(in: view).y):
            dismiss(animated: true)
        case .ended, .cancelled, .failed:
            UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseOut) {
                self.pageController.view.transform = .identity
                self.view.backgroundColor = .black
                [self.closeButton, self.positionLabel].forEach { $0.alpha = 1 }
            }
        default:
            break
        }
    }
}

/// The "2 of 4" capsule.
final class PositionLabel: UILabel {
    private static let insets = UIEdgeInsets(top: 6, left: 14, bottom: 6, right: 14)

    override init(frame: CGRect) {
        super.init(frame: frame)
        font = .monospacedDigitSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        textColor = .white
        backgroundColor = UIColor.black.withAlphaComponent(0.5)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(width: size.width + Self.insets.left + Self.insets.right, height: size.height + Self.insets.top + Self.insets.bottom)
    }

    override func drawText(in rect: CGRect) { super.drawText(in: rect.inset(by: Self.insets)) }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}
