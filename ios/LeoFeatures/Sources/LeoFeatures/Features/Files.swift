import ComposableArchitecture
import Foundation
import LeoKit

/// One agent's surfaced files, newest first, with unread dots. Opening a
/// file downloads it through LeoKit into a temporary folder for its
/// preview, which is deleted when the preview closes.
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
            case .alert, .delegate, .preview(.presented):
                return .none

            case .downloaded(let id, let result):
                guard state.opening == id, let file = state.files.first(where: { $0.id == id }) else {
                    if case .success(let preview) = result { return discard(preview.localURL) }
                    return .none
                }
                state.opening = nil
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

            case .preview(.dismiss):
                guard let url = state.preview?.localURL else { return .none }
                return discard(url)
            }
        }
        .ifLet(\.$alert, action: \.alert)
        .ifLet(\.$preview, action: \.preview) { FilePreview() }
    }

    private func open(_ file: LeoSurfacedFile, daemon: PairedDaemon) -> Effect<Action> {
        let (secrets, surfacedFiles) = (secrets, surfacedFiles)
        return .run { send in
            await send(.downloaded(file.id, Result {
                guard let saved = try secrets.load(daemon.id) else { throw MissingToken(daemonName: daemon.name) }
                let connection = DaemonConnection(daemon: daemon, secrets: saved)
                let named = FilePreviewKind(fileName: file.path)
                let download = try await surfacedFiles.download(connection, file, named.maxBytes, named.truncates)
                let text = named.readsText ? try await surfacedFiles.readText(download.url) : nil
                let kind: FilePreviewKind = named == .unknown ? (text == nil ? .quickLook : .text) : named
                return FilePreview.State(
                    file: file, localURL: download.url, kind: kind, text: text, totalBytes: download.totalBytes, isTruncated: download.isTruncated
                )
            }))
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
        public let file: LeoSurfacedFile
        public let localURL: URL
        public let kind: FilePreviewKind
        /// The (possibly truncated) text, for text and Markdown.
        public let text: String?
        public let totalBytes: Int64
        public let isTruncated: Bool
        public var isSharing = false

        public init(file: LeoSurfacedFile, localURL: URL, kind: FilePreviewKind, text: String?, totalBytes: Int64, isTruncated: Bool) {
            self.file = file
            self.localURL = localURL
            self.kind = kind
            self.text = text
            self.totalBytes = totalBytes
            self.isTruncated = isTruncated
        }

        public var line: Int? { file.line }
    }

    public enum Action: BindableAction {
        case binding(BindingAction<State>)
        case shareButtonTapped
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .binding:
                return .none
            case .shareButtonTapped:
                state.isSharing = true
                return .none
            }
        }
    }
}
