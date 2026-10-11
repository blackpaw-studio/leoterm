import ComposableArchitecture
import Foundation
import LeoKit

/// Downloads surfaced files for preview into a private temporary folder,
/// and cleans them up.
@DependencyClient
public struct SurfacedFileClient: Sendable {
    /// Downloads at most `maxBytes`; with `truncating` false a larger file
    /// throws `LeoFileDownloadError.tooLarge` instead.
    public var download: @Sendable (_ connection: DaemonConnection, _ file: LeoSurfacedFile, _ maxBytes: Int64, _ truncating: Bool) async throws -> LeoDownloadedFile
    /// The file as text, or nil when it looks binary.
    public var readText: @Sendable (_ url: URL) async throws -> String?
    /// Deletes a downloaded preview.
    public var discard: @Sendable (_ url: URL) -> Void
    /// Deletes every leftover preview (at launch).
    public var discardAll: @Sendable () -> Void
}

extension SurfacedFileClient: DependencyKey {
    public static let testValue = SurfacedFileClient()

    public static var liveValue: SurfacedFileClient {
        let session = URLSession(configuration: .default)
        let root = URL.temporaryDirectory.appending(path: "leo-previews", directoryHint: .isDirectory)
        return SurfacedFileClient(
            download: { connection, file, maxBytes, truncating in
                // One folder per download keeps the real file name (QuickLook
                // and the share sheet show it) without collisions.
                let url = root.appending(path: UUID().uuidString, directoryHint: .isDirectory).appending(path: Self.localName(for: file))
                let downloader = LeoSurfacedFileDownloader(transport: LeoHTTPSTransport(endpoint: connection.endpoint, session: session))
                return try await downloader.download(id: file.id, to: url, maxBytes: maxBytes, truncating: truncating)
            },
            readText: { url in
                FilePreviewKind.decodeText(try Data(contentsOf: url, options: .mappedIfSafe))
            },
            discard: { url in
                let folder = url.deletingLastPathComponent().standardizedFileURL
                guard folder.deletingLastPathComponent().path() == root.standardizedFileURL.path() else { return }
                try? FileManager.default.removeItem(at: folder)
            },
            discardAll: {
                try? FileManager.default.removeItem(at: root)
            }
        )
    }

    /// The surfaced file's name, safe as one path component.
    static func localName(for file: LeoSurfacedFile) -> String {
        let name = file.displayName
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespaces)
        return name.isEmpty || name.hasPrefix(".") ? "file\(name)" : name
    }
}

/// Which surfaced files the user has opened (LeoKit's ledger), persisted.
@DependencyClient
public struct SeenFilesClient: Sendable {
    public var load: @Sendable () -> LeoSurfacedFileLedger = { LeoSurfacedFileLedger() }
    public var save: @Sendable (_ ledger: LeoSurfacedFileLedger) -> Void
}

extension SeenFilesClient: DependencyKey {
    public static let testValue = SeenFilesClient()

    public static var liveValue: SeenFilesClient {
        let store = LeoUserDefaultsSurfacedFileSeenStore(defaults: .standard)
        return SeenFilesClient(load: { store.load() }, save: { store.save($0) })
    }
}

extension LeoUserDefaultsSurfacedFileSeenStore: @retroactive @unchecked Sendable {}

extension DependencyValues {
    public var surfacedFiles: SurfacedFileClient {
        get { self[SurfacedFileClient.self] }
        set { self[SurfacedFileClient.self] = newValue }
    }

    public var seenFiles: SeenFilesClient {
        get { self[SeenFilesClient.self] }
        set { self[SeenFilesClient.self] = newValue }
    }
}
