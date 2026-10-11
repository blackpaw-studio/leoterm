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
        attention: LeoAttentionSignal? = nil, harness: String? = "claude", startedAt: String? = nil,
        surfacedFiles: [LeoSurfacedFile] = []
    ) -> LeoObservedAgent {
        LeoObservedAgent(
            name: name, status: status, activity: activity, currentAction: nil, lastActivityAt: nil,
            attention: attention, startedAt: startedAt, surfacedFiles: surfacedFiles, template: "coding", harness: harness
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

extension LeoSurfacedFile {
    /// A file `zeus` (incarnation `s1`) surfaced; `minute` sets `at`.
    static func make(_ id: String, path: String? = nil, minute: Int? = nil, agent: String = "zeus", startedAt: String = "s1", line: Int? = nil) -> LeoSurfacedFile {
        let path = path ?? "docs/\(id).md"
        return LeoSurfacedFile(
            id: id, agent: agent, startedAt: startedAt, path: path, absPath: "/work/\(path)", line: line, reason: "look at \(id)",
            at: minute.map { String(format: "2026-10-10T10:%02d:00Z", $0) }
        )
    }
}

/// Generic one-stream-per-attempt queue for any element type.
final class Streams<Element: Sendable>: Sendable {
    typealias Stream = AsyncThrowingStream<Element, any Error>
    let continuations: [Stream.Continuation]
    private let streams: LockIsolated<[Stream]>
    let opened = LockIsolated(0)
    let terminated = LockIsolated(0)

    init(count: Int) {
        let pairs = (0..<count).map { _ in Stream.makeStream() }
        continuations = pairs.map(\.continuation)
        streams = LockIsolated(pairs.map(\.stream))
        for continuation in continuations {
            continuation.onTermination = { [terminated] _ in terminated.withValue { $0 += 1 } }
        }
    }

    func next() -> Stream {
        opened.withValue { $0 += 1 }
        return streams.withValue { $0.isEmpty ? Stream { $0.finish() } : $0.removeFirst() }
    }

    subscript(index: Int) -> Stream.Continuation { continuations[index] }
}
