import UIKit

/// The back button an editor's predecessor offers, without the long-press
/// history menu: that menu jumps past the editor's Save/Discard question.
/// The tap still goes through the editor's `navigationItem.backAction`.
final class NoHistoryBackBarButtonItem: UIBarButtonItem {
    override var menu: UIMenu? {
        get { nil }
        set {}
    }

    override init() {
        super.init()
        title = ""
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
