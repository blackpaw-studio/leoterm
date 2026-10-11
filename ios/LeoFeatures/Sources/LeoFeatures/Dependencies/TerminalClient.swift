import ComposableArchitecture
import Foundation
import LeoKit

/// The terminal size the phone reports when it attaches. The daemon's
/// client is `tmux attach -r` (read-only, ignore-size), so this never
/// resizes the Mac's window; it only sets how much of it the phone draws.
/// Matching the Mac's window shows all of it; the view zooms and pans.
public struct TerminalSize: Hashable, Sendable, RawRepresentable {
    public let cols: Int
    public let rows: Int

    public init(cols: Int, rows: Int) {
        self.cols = min(max(cols, 1), 1000)
        self.rows = min(max(rows, 1), 1000)
    }

    /// "160x48".
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        self.init(cols: parts[0], rows: parts[1])
    }

    public var rawValue: String { "\(cols)x\(rows)" }

    public static let compact = TerminalSize(cols: 80, rows: 24)
    public static let medium = TerminalSize(cols: 120, rows: 36)
    public static let standard = TerminalSize(cols: 160, rows: 48)
    public static let wide = TerminalSize(cols: 200, rows: 56)
    public static let extraWide = TerminalSize(cols: 240, rows: 64)
    public static let presets: [TerminalSize] = [.compact, .medium, .standard, .wide, .extraWide]
}

extension SharedKey where Self == AppStorageKey<TerminalSize>.Default {
    /// The size the phone asks for, remembered across launches.
    public static var terminalSize: Self { Self[.appStorage("terminalSize"), default: .standard] }
}

/// Opens read-only attaches to agents' tmux sessions.
@DependencyClient
public struct TerminalClient: Sendable {
    /// One attach. Yields `.opened`, then output; finishes by throwing how
    /// it ended. Cancelling the consumer closes the socket.
    public var attach: @Sendable (_ connection: DaemonConnection, _ agent: String, _ size: TerminalSize) -> AsyncThrowingStream<LeoTerminalEvent, any Error> = { _, _, _ in .finished() }
}

extension TerminalClient: DependencyKey {
    public static let testValue = TerminalClient()

    public static var liveValue: TerminalClient {
        let session = URLSession(configuration: .default)
        return TerminalClient(attach: { connection, agent, size in
            LeoURLSessionWebSocket.attach(endpoint: connection.endpoint, agent: agent, cols: size.cols, rows: size.rows, session: session)
        })
    }
}

/// What the terminal view feeds its emulator.
public enum TerminalOutput: Equatable, Sendable {
    /// A new attach opened: tmux redraws everything, so start clean.
    case reset
    case bytes(Data)
}

/// Carries terminal output from the `Terminal` feature's connection to the
/// view that renders it, outside reducer state (output is a byte stream,
/// not state). One subscriber per agent; a new one replaces the old.
public final class TerminalOutputBus: Sendable {
    private struct Subscriber {
        let token: UUID
        let continuation: AsyncStream<TerminalOutput>.Continuation
    }

    private let subscribers = LockIsolated<[AgentRef: Subscriber]>([:])

    public init() {}

    public func output(for ref: AgentRef) -> AsyncStream<TerminalOutput> {
        let (stream, continuation) = AsyncStream<TerminalOutput>.makeStream()
        let token = UUID()
        let previous = subscribers.withValue { subscribers in
            defer { subscribers[ref] = Subscriber(token: token, continuation: continuation) }
            return subscribers[ref]
        }
        previous?.continuation.finish()
        continuation.onTermination = { [subscribers] _ in
            subscribers.withValue { if $0[ref]?.token == token { $0[ref] = nil } }
        }
        return stream
    }

    /// Dropped when nobody is watching.
    public func send(_ output: TerminalOutput, to ref: AgentRef) {
        subscribers.value[ref]?.continuation.yield(output)
    }
}

extension TerminalOutputBus: DependencyKey {
    public static let liveValue = TerminalOutputBus()
    public static var testValue: TerminalOutputBus { TerminalOutputBus() }
}

extension DependencyValues {
    public var terminalClient: TerminalClient {
        get { self[TerminalClient.self] }
        set { self[TerminalClient.self] = newValue }
    }

    public var terminalOutput: TerminalOutputBus {
        get { self[TerminalOutputBus.self] }
        set { self[TerminalOutputBus.self] = newValue }
    }
}
