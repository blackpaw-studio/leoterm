import ComposableArchitecture
import LeoFeatures
import QuickLook
import UIKit

/// A downloaded image, PDF, video or office file in QuickLook, which brings
/// its own share button. Popping it discards the temporary file.
final class QuickLookPreviewController: QLPreviewController, QLPreviewControllerDataSource {
    private let store: StoreOf<FilePreview>
    private let item: Item

    init(store: StoreOf<FilePreview>) {
        self.store = store
        item = Item(previewItemURL: store.localURL, previewItemTitle: store.file.displayName)
        super.init(nibName: nil, bundle: nil)
        dataSource = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.accessibilityIdentifier = "file.quicklook"
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem { item }

    private final class Item: NSObject, QLPreviewItem {
        let previewItemURL: URL?
        let previewItemTitle: String?

        init(previewItemURL: URL, previewItemTitle: String) {
            self.previewItemURL = previewItemURL
            self.previewItemTitle = previewItemTitle
        }
    }
}
