import AVFoundation
import ComposableArchitecture
import LeoFeatures
import UIKit
import UserNotifications

extension AudioRecorderClient: @retroactive DependencyKey {
    /// AAC in an `.m4a`, mono 44.1 kHz; the recorder itself also stops at
    /// the composer's ten-minute cap.
    public static var liveValue: AudioRecorderClient {
        let recorder = VoiceRecorder()
        return AudioRecorderClient(
            requestPermission: { await AVAudioApplication.requestRecordPermission() },
            start: { url in try await recorder.start(url) },
            stop: { await recorder.stop() },
            cancel: { await recorder.cancel() }
        )
    }
}

@MainActor
private final class VoiceRecorder {
    private var recorder: AVAudioRecorder?

    func start(_ url: URL) throws {
        recorder?.stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record(forDuration: Composer.maximumRecording / .seconds(1)) else {
            throw RecorderError.couldNotStart
        }
        self.recorder = recorder
    }

    func stop() -> TimeInterval {
        guard let recorder else { return 0 }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        deactivate()
        return duration
    }

    func cancel() {
        recorder?.stop()
        recorder?.deleteRecording()
        recorder = nil
        deactivate()
    }

    private func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    enum RecorderError: Error, LocalizedError {
        case couldNotStart
        var errorDescription: String? { String(localized: "The microphone couldn't start recording.") }
    }
}

extension ChatNotifierClient: @retroactive DependencyKey {
    /// A local notification, since the app may be in the background when a
    /// notification's reply or answer fails.
    public static var liveValue: ChatNotifierClient {
        ChatNotifierClient(actionFailed: { agent, reason in
            let content = UNMutableNotificationContent()
            content.title = agent
            content.body = String(localized: "Couldn't send your response: \(reason)")
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        })
    }
}

extension BackgroundTaskClient: @retroactive DependencyKey {
    /// `UIApplication` background tasks. Ending is idempotent: the
    /// expiration handler and the caller may both end the same task.
    public static var liveValue: BackgroundTaskClient {
        let tasks = BackgroundTasks()
        return BackgroundTaskClient(
            begin: { name in await tasks.begin(name) },
            end: { token in await tasks.end(token) }
        )
    }
}

@MainActor
private final class BackgroundTasks {
    private var live: Set<Int> = []

    func begin(_ name: String) -> Int {
        var identifier = UIBackgroundTaskIdentifier.invalid
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // Out of time: the in-flight request fails when the app is
            // suspended, and the draft stays for a retry.
            self?.end(identifier.rawValue)
        }
        if identifier != .invalid { live.insert(identifier.rawValue) }
        return identifier.rawValue
    }

    func end(_ token: Int) {
        guard live.remove(token) != nil else { return }
        UIApplication.shared.endBackgroundTask(UIBackgroundTaskIdentifier(rawValue: token))
    }
}
