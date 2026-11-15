import AVFoundation
import Foundation

/// Records one voice note at a time. `onLimit` fires when the recorder
/// stopped itself at `limit`; `stop` still returns the length then.
@MainActor protocol LeoChatVoiceRecording: AnyObject {
    func requestPermission() async -> Bool
    func start(url: URL, limit: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws
    /// Finalizes the file and returns its length in seconds.
    func stop() -> TimeInterval
    /// Stops and deletes the file.
    func cancel()
}

/// AAC in an `.m4a`, mono 44.1 kHz, through `AVAudioRecorder`.
@MainActor final class LeoChatVoiceRecorder: NSObject, LeoChatVoiceRecording, AVAudioRecorderDelegate {
    enum Failure: Error, LocalizedError {
        case couldNotStart
        var errorDescription: String? { "The microphone couldn't start recording." }
    }

    private var recorder: AVAudioRecorder?
    private var limit: TimeInterval = 0
    /// Set once the recorder stopped itself at the cap.
    private var reachedLimit = false
    private var onLimit: (@MainActor () -> Void)?

    func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    func start(url: URL, limit: TimeInterval, onLimit: @escaping @MainActor () -> Void) throws {
        recorder?.stop()
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        guard recorder.record(forDuration: limit) else { throw Failure.couldNotStart }
        self.recorder = recorder
        self.limit = limit
        self.onLimit = onLimit
        reachedLimit = false
    }

    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = reachedLimit ? limit : recorder.currentTime
        recorder.delegate = nil
        recorder.stop()
        self.recorder = nil
        onLimit = nil
        return duration
    }

    func cancel() {
        guard let recorder else { return }
        recorder.delegate = nil
        recorder.stop()
        recorder.deleteRecording()
        self.recorder = nil
        onLimit = nil
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, let current = self.recorder, ObjectIdentifier(current) == id else { return }
            self.reachedLimit = true
            self.onLimit?()
        }
    }
}
