import ComposableArchitecture
import Foundation

/// The paired-daemon list (no secrets), persisted as JSON.
@DependencyClient
public struct PairedDaemonsClient: Sendable {
    public var load: @Sendable () throws -> [PairedDaemon]
    public var save: @Sendable (_ daemons: [PairedDaemon]) throws -> Void
}

extension PairedDaemonsClient: DependencyKey {
    public static let testValue = PairedDaemonsClient()

    public static var liveValue: PairedDaemonsClient { live(directory: .applicationSupportDirectory) }

    /// `paired-daemons.json` in `directory`.
    static func live(directory: URL) -> PairedDaemonsClient {
        let url = directory.appending(path: "paired-daemons.json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return PairedDaemonsClient(
            load: {
                guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return [] }
                return try decoder.decode([PairedDaemon].self, from: Data(contentsOf: url))
            },
            save: { daemons in
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try encoder.encode(daemons).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            }
        )
    }
}

extension DependencyValues {
    public var pairedDaemons: PairedDaemonsClient {
        get { self[PairedDaemonsClient.self] }
        set { self[PairedDaemonsClient.self] = newValue }
    }
}

/// The name this device reports when pairing (the daemon lists it in
/// `leo devices list`). The app sets the live value from UIDevice.
public enum DeviceNameKey: DependencyKey {
    public static let liveValue = "Leo for iOS"
    public static let testValue = "Test iPhone"
}

extension DependencyValues {
    public var deviceName: String {
        get { self[DeviceNameKey.self] }
        set { self[DeviceNameKey.self] = newValue }
    }
}
