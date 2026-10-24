import ComposableArchitecture
import LeoFeatures
import UIKit

/// A collection resource's list (Templates, Environments).
final class ConfigCollectionViewController: UIViewController {
    private let store: StoreOf<ConfigCollection>

    init(store: StoreOf<ConfigCollection>) {
        self.store = store
        super.init(nibName: nil, bundle: nil)
        title = store.core.title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
