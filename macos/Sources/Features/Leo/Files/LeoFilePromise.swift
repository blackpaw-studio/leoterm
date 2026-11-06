import AppKit
import UniformTypeIdentifiers

/// A file promised to Finder on a drag out of Leo (workspace browser,
/// chat attachments). The file is produced only once it is dropped, so a
/// remote one is downloaded then, never while dragging. AppKit holds a
/// coordinated write on the drop URL until the completion runs, so
/// `writePromiseTo` starts `write` and returns at once, and the completion
/// runs exactly once, whatever happens.
class LeoFilePromise: NSFilePromiseProvider, NSFilePromiseProviderDelegate {
    /// Shared by every promise: AppKit calls the delegate on it, never on
    /// the main queue.
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Leo file promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The name Finder gives the dropped file.
    let fileName: String
    private let write: @MainActor @Sendable (URL) async throws -> Void

    /// `write` produces the file at the drop URL; it runs on the main
    /// actor, so it should return promptly and await its real work.
    @MainActor init(fileName: String, write: @escaping @MainActor @Sendable (URL) async throws -> Void) {
        self.fileName = fileName
        self.write = write
        super.init()
        fileType = Self.fileType(forName: fileName)
        delegate = self
    }

    /// The type named by the file's extension, `public.data` without one.
    static func fileType(forName name: String) -> String {
        let pathExtension = (name as NSString).pathExtension
        return (pathExtension.isEmpty ? nil : UTType(filenameExtension: pathExtension, conformingTo: .data))?.identifier
            ?? UTType.data.identifier
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        fileName
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        Self.queue
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let write = write
        Task { @MainActor in
            do {
                try await write(url)
                completionHandler(nil)
            } catch {
                completionHandler(error)
            }
        }
    }
}
