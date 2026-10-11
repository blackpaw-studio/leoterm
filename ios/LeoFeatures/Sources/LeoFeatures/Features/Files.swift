import ComposableArchitecture
import Foundation
import LeoKit

/// One agent's surfaced files, newest first, with unread dots. Opening a
/// file downloads it through LeoKit into a temporary folder for its
/// preview, which is deleted once the preview leaves state.
@Reducer
public struct Files {
    @ObservableState
    public struct State: Equatable {
        public var daemon: PairedDaemon
        public let agentName: String
        /// Newest first; kept in step by the parent from the fleet's index.
        public var files: [LeoSurfacedFile]
        /// Kept in step by the parent from the seen ledger.
        public var unseenIDs: Set<String>
        /// Files the daemon answered 404 for (evicted, or deleted).
        public var unavailableIDs: Set<String> = []
        /// The file being downloaded.
        public var opening: LeoSurfacedFile.ID?
        @Presents public var alert: AlertState<Never>?
        @Presents public var preview: FilePreview.State?

        public init(daemon: PairedDaemon, agentName: String, files: [LeoSurfacedFile], unseenIDs: Set<String>) {
            self.daemon = daemon
            self.agentName = agentName
            self.files = files
            self.unseenIDs = unseenIDs
        }
    }

    public enum Action {
        case alert(PresentationAction<Never>)
        case delegate(Delegate)
        case downloaded(LeoSurfacedFile.ID, Result<FilePreview.State, any Error>)
        case fileTapped(LeoSurfacedFile.ID)
        case preview(PresentationAction<FilePreview.Action>)

        @CasePathable
        public enum Delegate {
            /// The user opened `file` (or found it gone): mark it seen.
            case opened(LeoSurfacedFile)
        }
    }

    @Dependency(\.secrets) var secrets
    @Dependency(\.surfacedFiles) var surfacedFiles

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .alert, .delegate:
                return .none

            case .downloaded(let id, let result):
                // Free the list first: the file may have left it mid-download.
                let wasOpening = state.opening == id
                if wasOpening { state.opening = nil }
                guard wasOpening, let file = state.files.first(where: { $0.id == id }) else {
                    if case .success(let preview) = result { return discard(preview.localURL) }
                    return .none
                }
                switch result {
                case .success(let preview):
                    state.preview = preview
                case .failure(LeoFileDownloadError.noLongerAvailable):
                    state.unavailableIDs.insert(id)
                    state.alert = Self.unavailableAlert(file)
                case .failure(let error):
                    state.alert = Self.failureAlert(file, error)
                    return .none
                }
                return .send(.delegate(.opened(file)))

            case .fileTapped(let id):
                guard state.opening == nil, state.preview == nil, let file = state.files.first(where: { $0.id == id }) else { return .none }
                state.opening = id
                return open(file, daemon: state.daemon)

            case .preview:
                // A closed preview's files are deleted by `DiscardingPreviews`
                // at the root, which also sees its agent or daemon go.
                return .none
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$preview, action: \.preview) { FilePreview() }
    }

    private func open(_ file: LeoSurfacedFile, daemon: PairedDaemon) -> Effect<Action> {
        let (secrets, surfacedFiles) = (secrets, surfacedFiles)
        return .run { send in
            let result = await Result {
                guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
                let connection = DaemonConnection(daemon: daemon, secrets: saved)
                let named = FilePreviewKind(fileName: file.path)
                let download = try await surfacedFiles.download(connection, file, named.maxBytes, named.truncates)
                let text = named.readsText ? try await surfacedFiles.readText(download.url) : nil
                let kind: FilePreviewKind = named == .unknown ? (text == nil ? .quickLook : .text) : named
                return FilePreview.State(
                    daemon: daemon, file: file, localURL: download.url, kind: kind, text: text, totalBytes: download.totalBytes, isTruncated: download.isTruncated
                )
            }
            // Its screen closed meanwhile: nobody will own the file.
            if Task.isCancelled, case .success(let preview) = result { return surfacedFiles.discard(preview.localURL) }
            await send(.downloaded(file.id, result))
        }
    }

    private func discard(_ url: URL) -> Effect<Action> {
        let surfacedFiles = surfacedFiles
        return .run { _ in surfacedFiles.discard(url) }
    }

    static func unavailableAlert(_ file: LeoSurfacedFile) -> AlertState<Never> {
        AlertState {
            TextState("No Longer Available")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState("The daemon no longer has \(file.displayName). It keeps each agent's 20 most recent files until it restarts.")
        }
    }

    static func failureAlert(_ file: LeoSurfacedFile, _ error: any Error) -> AlertState<Never> {
        AlertState {
            TextState("Couldn't Open \(file.displayName)")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(error.localizedDescription)
        }
    }
}

/// A downloaded surfaced file on screen: QuickLook, or the text/Markdown
/// viewer scrolled to the agent's `line`, with a share sheet.
@Reducer
public struct FilePreview {
    @ObservableState
    public struct State: Equatable {
        public let daemon: PairedDaemon
        public let file: LeoSurfacedFile
        public let localURL: URL
        public let kind: FilePreviewKind
        /// The (possibly truncated) text, for text and Markdown.
        public let text: String?
        public let totalBytes: Int64
        public let isTruncated: Bool
        /// The whole file, fetched for sharing when the preview holds only
        /// its start.
        public var fullFileURL: URL?
        public var isPreparingShare = false
        public var isSharing = false
        @Presents public var alert: AlertState<Never>?

        public init(
            daemon: PairedDaemon, file: LeoSurfacedFile, localURL: URL, kind: FilePreviewKind, text: String?, totalBytes: Int64, isTruncated: Bool
        ) {
            self.daemon = daemon
            self.file = file
            self.localURL = localURL
            self.kind = kind
            self.text = text
            self.totalBytes = totalBytes
            self.isTruncated = isTruncated
        }

        public var line: Int? { file.line }

        /// What the share sheet hands on: the whole file, never the excerpt.
        public var shareURL: URL? { isTruncated ? fullFileURL : localURL }

        /// Every temporary file this preview owns.
        public var temporaryFiles: [URL] { [localURL] + (fullFileURL.map { [$0] } ?? []) }
    }

    public enum Action: BindableAction {
        case alert(PresentationAction<Never>)
        case binding(BindingAction<State>)
        case fullFileDownloaded(Result<URL, any Error>)
        case shareButtonTapped
    }

    @Dependency(\.secrets) var secrets
    @Dependency(\.surfacedFiles) var surfacedFiles

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .alert, .binding:
                return .none

            case .fullFileDownloaded(.success(let url)):
                state.isPreparingShare = false
                state.fullFileURL = url
                state.isSharing = true
                return .none

            case .fullFileDownloaded(.failure(let error)):
                state.isPreparingShare = false
                state.alert = Self.shareFailedAlert(error)
                return .none

            case .shareButtonTapped:
                guard state.shareURL == nil else {
                    state.isSharing = true
                    return .none
                }
                guard !state.isPreparingShare else { return .none }
                state.isPreparingShare = true
                return downloadWholeFile(state)
            }
        }
        .ifLet(\.$alert, action: \.alert)
    }

    /// The whole file (QuickLook's cap applies), for the share sheet.
    private func downloadWholeFile(_ state: State) -> Effect<Action> {
        let (daemon, file, secrets, surfacedFiles) = (state.daemon, state.file, secrets, surfacedFiles)
        return .run { send in
            let result = await Result {
                guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
                let connection = DaemonConnection(daemon: daemon, secrets: saved)
                return try await surfacedFiles.download(connection, file, FilePreviewKind.quickLookCap, false).url
            }
            // Closed meanwhile: nobody will own the file.
            if Task.isCancelled, case .success(let url) = result { return surfacedFiles.discard(url) }
            await send(.fullFileDownloaded(result))
        }
    }

    static func shareFailedAlert(_ error: any Error) -> AlertState<Never> {
        AlertState {
            TextState("Couldn't Share the File")
        } actions: {
            ButtonState(role: .cancel) { TextState("OK") }
        } message: {
            TextState(error.localizedDescription)
        }
    }
}
