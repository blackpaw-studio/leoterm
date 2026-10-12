import ComposableArchitecture
import Foundation

/// A chat thread's composer: text, picked attachments, and hold-to-record
/// voice notes (sent as soon as the button is released, capped at ten
/// minutes). The thread does the sending and resets the composer.
@Reducer
public struct Composer {
    /// The longest voice note.
    public static let maximumRecording: Duration = .seconds(600)
    /// Anything shorter was a tap, not a recording.
    public static let minimumRecording: TimeInterval = 0.5

    public enum Recording: Equatable, Sendable {
        case idle
        /// Waiting for the microphone permission and the recorder.
        case requesting
        case recording(url: URL, startedAt: Date)
        /// Released; the recorder is finalizing the file.
        case finishing
    }

    public enum Hint: Equatable, Sendable {
        case failed(String)
        case holdToRecord
        case microphoneDenied
    }

    public struct Outgoing: Equatable, Sendable {
        public let text: String
        public let files: [ChatFile]
    }

    @ObservableState
    public struct State: Equatable {
        public var attachments: IdentifiedArrayOf<ChatFile> = []
        public var hint: Hint?
        public var isSending = false
        public var recording: Recording = .idle
        public var text = ""

        public init() {}

        /// What the send button would send; nil when there is nothing.
        public var outgoing: Outgoing? {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty || !attachments.isEmpty else { return nil }
            return Outgoing(text: trimmed, files: Array(attachments))
        }

        public var canSend: Bool { outgoing != nil && !isSending }
        public var isRecording: Bool { recording != .idle }

        /// After a successful send.
        mutating func reset() {
            attachments = []
            hint = nil
            isSending = false
            text = ""
        }
    }

    public enum Action: BindableAction {
        case attachmentPicked(ChatFile)
        case binding(BindingAction<State>)
        case delegate(Delegate)
        /// A tap (not a hold) on the mic.
        case micTapped
        case recordButtonCancelled
        case recordButtonPressed
        case recordButtonReleased
        case recordingCapReached
        case recordingFailed(String)
        case recordingFinished(url: URL, duration: TimeInterval)
        case recordingPermissionDenied
        case recordingStarted(URL)
        case removeAttachmentTapped(ChatFile.ID)
        case sendButtonTapped

        @CasePathable
        public enum Delegate {
            case send(Outgoing)
        }
    }

    enum CancelID { case recording }

    @Dependency(\.audioRecorder) var audioRecorder
    @Dependency(\.continuousClock) var clock
    @Dependency(\.date.now) var now
    @Dependency(\.uuid) var uuid

    public init() {}

    public var body: some ReducerOf<Self> {
        BindingReducer()
        Reduce { state, action in
            switch action {
            case .attachmentPicked(let file):
                state.attachments.append(file)
                state.hint = nil
                return .none

            case .binding(\.text):
                state.hint = nil
                return .none

            case .binding, .delegate:
                return .none

            case .micTapped:
                state.hint = .holdToRecord
                return .none

            case .recordButtonCancelled:
                guard state.recording != .idle else { return .none }
                state.recording = .idle
                let audioRecorder = audioRecorder
                return .concatenate(.cancel(id: CancelID.recording), .run { _ in await audioRecorder.cancel() })

            case .recordButtonPressed:
                guard state.recording == .idle, !state.isSending else { return .none }
                state.recording = .requesting
                state.hint = nil
                let url = Self.voiceNoteURL(uuid())
                return .run { [audioRecorder, clock] send in
                    guard await audioRecorder.requestPermission() else {
                        await send(.recordingPermissionDenied)
                        return
                    }
                    // Released while the permission prompt was up.
                    try Task.checkCancellation()
                    do {
                        try await audioRecorder.start(url)
                    } catch {
                        await send(.recordingFailed(error.localizedDescription))
                        return
                    }
                    await send(.recordingStarted(url))
                    try await clock.sleep(for: Self.maximumRecording)
                    await send(.recordingCapReached)
                }
                .cancellable(id: CancelID.recording, cancelInFlight: true)

            case .recordButtonReleased, .recordingCapReached:
                switch state.recording {
                case .requesting:
                    state.recording = .idle
                    return .cancel(id: CancelID.recording)
                case .recording(let url, _):
                    state.recording = .finishing
                    return .concatenate(
                        .cancel(id: CancelID.recording),
                        .run { [audioRecorder] send in
                            await send(.recordingFinished(url: url, duration: await audioRecorder.stop()))
                        }
                    )
                case .idle, .finishing:
                    return .none
                }

            case .recordingFailed(let reason):
                state.recording = .idle
                state.hint = .failed(reason)
                return .none

            case .recordingFinished(let url, let duration):
                state.recording = .idle
                guard duration >= Self.minimumRecording else {
                    state.hint = .holdToRecord
                    return .run { _ in try? FileManager.default.removeItem(at: url) }
                }
                let voice = ChatFile(id: uuid(), url: url, filename: String(localized: "Voice note.m4a"), mime: "audio/mp4", kind: .voice)
                return .send(.delegate(.send(Outgoing(text: "", files: [voice]))))

            case .recordingPermissionDenied:
                state.recording = .idle
                state.hint = .microphoneDenied
                return .none

            case .recordingStarted(let url):
                // Released or cancelled while the recorder was starting.
                guard state.recording == .requesting else { return .run { [audioRecorder] _ in await audioRecorder.cancel() } }
                state.recording = .recording(url: url, startedAt: now)
                return .none

            case .removeAttachmentTapped(let id):
                state.attachments.remove(id: id)
                return .none

            case .sendButtonTapped:
                guard !state.isSending, let outgoing = state.outgoing else { return .none }
                state.isSending = true
                return .send(.delegate(.send(outgoing)))
            }
        }
    }

    public static func voiceNoteURL(_ id: UUID) -> URL {
        URL.temporaryDirectory.appending(path: "voice-\(id.uuidString).m4a")
    }
}
