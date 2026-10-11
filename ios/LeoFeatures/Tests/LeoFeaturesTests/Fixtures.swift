import ComposableArchitecture
import Foundation
import LeoKit

@testable import LeoFeatures

extension PairedDaemon {
    static let dionysus = PairedDaemon(
        id: "d-dionysus", name: "dionysus", baseURL: URL(string: "https://leo.example.com")!,
        urls: [URL(string: "https://leo.example.com")!], deviceID: "dev-1", pairedAt: Date(timeIntervalSince1970: 1_000)
    )
    static let hestia = PairedDaemon(
        id: "d-hestia", name: "hestia", baseURL: URL(string: "http://10.0.2.5:8370")!,
        urls: [URL(string: "http://10.0.2.5:8370")!], deviceID: "dev-2", pairedAt: Date(timeIntervalSince1970: 2_000)
    )
}

extension LeoObservedAgent {
    static func make(
        _ name: String, status: LeoAgentStatus = .running, activity: LeoActivity = .idle,
        attention: LeoAttentionSignal? = nil, harness: String? = "claude"
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: status, activity: activity, currentAction: nil, lastActivityAt: nil,
            attention: attention, template: "coding", harness: harness
        )
    }
}

extension LeoAttentionSignal {
    static func state(_ state: LeoAttentionState, _ revision: Int) -> LeoAttentionSignal {
        LeoAttentionSignal(state: state, revision: revision)
    }
}

/// Event streams handed out in order, one per connection attempt; created
/// up front so a test can end a stream before the reducer has opened it.
final class StreamQueue: Sendable {
    typealias Stream = AsyncThrowingStream<LeoObserveEvent, any Error>
    let continuations: [Stream.Continuation]
    private let streams: LockIsolated<[Stream]>
    let opened = LockIsolated<[String]>([])

    init(count: Int) {
        let pairs = (0..<count).map { _ in Stream.makeStream() }
        continuations = pairs.map(\.continuation)
        streams = LockIsolated(pairs.map(\.stream))
    }

    func next(_ connection: DaemonConnection) -> Stream {
        opened.withValue { $0.append(connection.daemonID) }
        return streams.withValue { $0.isEmpty ? Stream { $0.finish() } : $0.removeFirst() }
    }

    subscript(index: Int) -> Stream.Continuation { continuations[index] }
}
