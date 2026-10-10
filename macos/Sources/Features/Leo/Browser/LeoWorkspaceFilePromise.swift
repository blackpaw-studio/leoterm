import AppKit
import UniformTypeIdentifiers

/// A workspace file dragged out of the browser (B-279). Finder gets a file
/// promise, so a remote file is downloaded only once it is dropped, and a
/// local one goes through the very same path (`LeoWorkspaceBrowserModel
/// .download`). AppKit holds a coordinated write on the drop URL until the
/// completion runs, so the write starts the download and returns at once,
/// and the completion runs exactly once, whatever happens.
final class LeoWorkspaceFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// Shared by every promise: AppKit calls the delegate on it, never on
    /// the main queue.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Leo workspace file promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    let entry: LeoWorkspaceEntry
    private weak var model: LeoWorkspaceBrowserModel?

    init(entry: LeoWorkspaceEntry, model: LeoWorkspaceBrowserModel) {
        self.entry = entry
        self.model = model
        super.init()
        let pathExtension = (entry.name as NSString).pathExtension
        fileType = (pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension, conformingTo: .data))?.identifier
            ?? UTType.data.identifier
        delegate = self
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        entry.name
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let path = entry.path
        Task { @MainActor [weak model] in
            guard let model else { return completionHandler(LeoFileAccessError.closed) }
            do {
                try await model.download(path, to: url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
