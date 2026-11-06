import AppKit
import LeoKit

/// A workspace file dragged out of the browser (B-279). Finder gets a file
/// promise, so a remote file is downloaded only once it is dropped, and a
/// local one goes through the very same path (`LeoWorkspaceBrowserModel
/// .download`).
final class LeoWorkspaceFilePromise: LeoFilePromise {
    let entry: LeoWorkspaceEntry

    @MainActor init(entry: LeoWorkspaceEntry, model: LeoWorkspaceBrowserModel) {
        self.entry = entry
        // The root the file was dragged from: Finder may ask for the file
        // only after the browser moved on, even to another host with the
        // same workspace path, whose file must never be downloaded in its
        // place.
        let rootGeneration = model.rootGeneration
        let path = entry.path
        super.init(fileName: entry.name) { [weak model] url in
            guard let model else { throw LeoFileAccessError.closed }
            try await model.download(path, to: url, fromRootGeneration: rootGeneration)
        }
    }
}
