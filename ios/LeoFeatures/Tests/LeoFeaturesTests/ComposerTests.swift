import ComposableArchitecture
import Foundation
import LeoKit
import Testing

@testable import LeoFeatures

@MainActor
struct ComposerTests {
    static let photo = ChatFile(id: UUID(0), url: URL(filePath: "/tmp/a.jpg"), filename: "a.jpg", mime: "image/jpeg", kind: .photo)

    @Test func sendingTrimsTheTextAndHandsOverTheAttachments() async {
        var state = Composer.State()
        state.text = "  ship it \n"
        state.attachments = [Self.photo]
        let store = TestStore(initialState: state) { Composer() }

        await store.send(.sendButtonTapped) { $0.isSending = true }
        await store.receive(\.delegate.send)
    }

    @Test func nothingToSendDoesNothing() async {
        var state = Composer.State()
        state.text = "   "
        let store = TestStore(initialState: state) { Composer() }
        await store.send(.sendButtonTapped)
    }

    @Test func aSendInFlightBlocksAnother() async {
        var state = Composer.State()
        state.text = "x"
        state.isSending = true
        let store = TestStore(initialState: state) { Composer() }
        await store.send(.sendButtonTapped)
    }

    @Test func theSendDelegateCarriesTrimmedTextAndFiles() {
        var state = Composer.State()
        state.text = "  ship it \n"
        state.attachments = [Self.photo]
        #expect(state.outgoing == Composer.Outgoing(text: "ship it", files: [Self.photo]))
    }

    @Test func removingAnAttachment() async {
        var state = Composer.State()
        state.attachments = [Self.photo]
        let store = TestStore(initialState: state) { Composer() }
        await store.send(.removeAttachmentTapped(Self.photo.id)) { $0.attachments = [] }
    }

    @Test func holdingRecordsAndReleasingSendsTheVoiceNote() async {
        let clock = TestClock()
        let started = LockIsolated<[URL]>([])
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 100)
            $0.audioRecorder.requestPermission = { true }
            $0.audioRecorder.start = { url in started.withValue { $0.append(url) } }
            $0.audioRecorder.stop = { 4.2 }
        }
        let url = Composer.voiceNoteURL(UUID(0))

        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingStarted) { $0.recording = .recording(url: url, startedAt: Date(timeIntervalSince1970: 100)) }
        #expect(started.value == [url])
        await store.send(.recordButtonReleased) { $0.recording = .finishing }
        await store.receive(\.recordingFinished) { $0.recording = .idle }
        let voice = ChatFile(id: UUID(1), url: url, filename: "Voice note.m4a", mime: "audio/mp4", kind: .voice)
        await store.receive(\.delegate.send, Composer.Outgoing(text: "", files: [voice]))
    }

    @Test func aTapTooShortToRecordIsDiscardedWithAHint() async {
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 100)
            $0.audioRecorder.requestPermission = { true }
            $0.audioRecorder.start = { _ in }
            $0.audioRecorder.stop = { 0.2 }
        }
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingStarted) { $0.recording = .recording(url: Composer.voiceNoteURL(UUID(0)), startedAt: Date(timeIntervalSince1970: 100)) }
        await store.send(.recordButtonReleased) { $0.recording = .finishing }
        await store.receive(\.recordingFinished) {
            $0.recording = .idle
            $0.hint = .holdToRecord
        }
    }

    @Test func recordingStopsItselfAtTheTenMinuteCap() async {
        let clock = TestClock()
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.continuousClock = clock
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 100)
            $0.audioRecorder.requestPermission = { true }
            $0.audioRecorder.start = { _ in }
            $0.audioRecorder.stop = { 600 }
        }
        let url = Composer.voiceNoteURL(UUID(0))
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingStarted) { $0.recording = .recording(url: url, startedAt: Date(timeIntervalSince1970: 100)) }
        await clock.advance(by: .seconds(599))
        await clock.advance(by: .seconds(1))
        await store.receive(\.recordingCapReached) { $0.recording = .finishing }
        await store.receive(\.recordingFinished) { $0.recording = .idle }
        await store.receive(\.delegate.send)
        // Releasing after the cap does nothing more.
        await store.send(.recordButtonReleased)
    }

    @Test func draggingAwayCancelsTheRecording() async {
        let cancelled = LockIsolated(false)
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.uuid = .incrementing
            $0.date.now = Date(timeIntervalSince1970: 100)
            $0.audioRecorder.requestPermission = { true }
            $0.audioRecorder.start = { _ in }
            $0.audioRecorder.cancel = { cancelled.setValue(true) }
        }
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingStarted) { $0.recording = .recording(url: Composer.voiceNoteURL(UUID(0)), startedAt: Date(timeIntervalSince1970: 100)) }
        await store.send(.recordButtonCancelled) { $0.recording = .idle }
        await store.finish()
        #expect(cancelled.value)
    }

    @Test func aDeniedMicrophoneSaysSo() async {
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.audioRecorder.requestPermission = { false }
        }
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingPermissionDenied) {
            $0.recording = .idle
            $0.hint = .microphoneDenied
        }
    }

    @Test func releasingWhileAskingForTheMicrophoneStopsTheStart() async {
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.audioRecorder.requestPermission = { try? await Task.never(); return true }
        }
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.send(.recordButtonReleased) { $0.recording = .idle }
    }

    @Test func aRecorderFailureIsShown() async {
        struct Failure: Error, LocalizedError { var errorDescription: String? { "no input" } }
        let store = TestStore(initialState: Composer.State()) {
            Composer()
        } withDependencies: {
            $0.uuid = .incrementing
            $0.audioRecorder.requestPermission = { true }
            $0.audioRecorder.start = { _ in throw Failure() }
        }
        await store.send(.recordButtonPressed) { $0.recording = .requesting }
        await store.receive(\.recordingFailed) {
            $0.recording = .idle
            $0.hint = .failed("no input")
        }
    }

    @Test func typingClearsAHint() async {
        var state = Composer.State()
        state.hint = .holdToRecord
        let store = TestStore(initialState: state) { Composer() }
        await store.send(.binding(.set(\.text, "h"))) {
            $0.text = "h"
            $0.hint = nil
        }
    }
}
