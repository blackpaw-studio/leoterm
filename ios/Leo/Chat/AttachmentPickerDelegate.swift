import LeoFeatures
import OSLog
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// Turns camera shots, photo-library picks and Files picks into local
/// `ChatFile`s (copied into a private temporary folder) for the composer.
@MainActor
final class AttachmentPickerDelegate: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate,
    PHPickerViewControllerDelegate, UIDocumentPickerDelegate {
    private nonisolated static let logger = Logger(subsystem: "studio.blackpaw.leo.ios", category: "chat")
    private static let jpegQuality: CGFloat = 0.85

    private let picked: (ChatFile) -> Void
    private let folder = URL.temporaryDirectory.appending(path: "leo-chat-outbox", directoryHint: .isDirectory)

    init(picked: @escaping (ChatFile) -> Void) {
        self.picked = picked
    }

    // MARK: Camera

    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage, let data = image.jpegData(compressionQuality: Self.jpegQuality) else { return }
        let name = "Photo \(Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))).jpg"
            .replacingOccurrences(of: ":", with: "-")
        store(data, name: name, mime: "image/jpeg", kind: .photo)
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }

    // MARK: Photo library

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            guard let type = provider.registeredContentTypes.first(where: { $0.conforms(to: .image) }) else { continue }
            let suggested = provider.suggestedName ?? "Photo"
            _ = provider.loadFileRepresentation(for: type, openInPlace: false) { [weak self] url, _, error in
                guard let url, let data = try? Data(contentsOf: url) else {
                    Self.logger.error("chat: photo pick failed \(error?.localizedDescription ?? "no file", privacy: .public)")
                    return
                }
                let ext = type.preferredFilenameExtension ?? url.pathExtension
                let mime = type.preferredMIMEType ?? "image/jpeg"
                Task { @MainActor [weak self] in
                    self?.store(data, name: "\(suggested).\(ext)", mime: mime, kind: .photo)
                }
            }
        }
    }

    // MARK: Files

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        for url in urls {
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            let destination = uniqueFolder().appending(path: url.lastPathComponent)
            do {
                try FileManager.default.moveItem(at: url, to: destination)
                picked(ChatFile(id: UUID(), url: destination, filename: url.lastPathComponent, mime: mime, kind: .file))
            } catch {
                Self.logger.error("chat: file pick failed \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func store(_ data: Data, name: String, mime: String, kind: ChatFile.Kind) {
        let url = uniqueFolder().appending(path: name)
        do {
            try data.write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
            picked(ChatFile(id: UUID(), url: url, filename: name, mime: mime, kind: kind))
        } catch {
            Self.logger.error("chat: saving a picked photo failed \(error.localizedDescription, privacy: .public)")
        }
    }

    /// One folder per file keeps its real name without collisions.
    private func uniqueFolder() -> URL {
        let url = folder.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
