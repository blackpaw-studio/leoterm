@testable import Ghostty
@testable import LeoKit

extension LeoEditorDocument {
    /// An edit from a view that shows the current revision.
    func edit(_ newText: String) {
        edit(newText, revision: contentRevision)
    }
}
