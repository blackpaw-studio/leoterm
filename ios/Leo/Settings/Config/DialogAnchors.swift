import UIKit

/// An action sheet is a popover on iPad, and UIKit raises when one has
/// nothing to point at. These give every settings sheet its anchor.
extension UIAlertController {
    /// Points at a bar button, as the question about a save does at Save.
    func anchored(to item: UIBarButtonItem) -> UIAlertController {
        popoverPresentationController?.barButtonItem = item
        return self
    }

    /// Points at the system back button's corner of the navigation bar, as a
    /// leave question does; at the screen's own view when it has no bar.
    func anchoredToBack(of viewController: UIViewController) -> UIAlertController {
        guard let popover = popoverPresentationController else { return self }
        if let bar = viewController.navigationController?.navigationBar {
            popover.sourceView = bar
            popover.sourceRect = CGRect(x: bar.layoutMargins.left, y: bar.bounds.midY, width: 44, height: 0)
        } else {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(x: viewController.view.bounds.midX, y: viewController.view.bounds.midY, width: 0, height: 0)
        }
        return self
    }
}
