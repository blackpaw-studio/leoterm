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
    public static let large = TerminalSize(cols: 160, rows: 48)
    /// The size leo creates agent sessions at (`tmux new-session -x 200 -y 50`).
    public static let standard = TerminalSize(cols: 200, rows: 50)
    public static let wide = TerminalSize(cols: 240, rows: 64)
    public static let presets: [TerminalSize] = [.compact, .medium, .large, .standard, .wide]
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
/// Output the view hasn't taken yet coalesces, up to `cap` bytes; past
/// that the backlog is dropped and the sender told to resync, since a
/// terminal missing bytes would show corrupt state.
public final class TerminalOutputBus: Sendable {
    /// Output a subscriber may fall behind by before it must resync.
    public static let defaultCap = 1 << 20

    private let subscribers = LockIsolated<[AgentRef: TerminalOutputBuffer]>([:])
    private let cap: Int

    public init(cap: Int = TerminalOutputBus.defaultCap) {
        self.cap = cap
    }

    public func output(for ref: AgentRef) -> AsyncStream<TerminalOutput> {
        let buffer = TerminalOutputBuffer(cap: cap)
        let previous = subscribers.withValue { subscribers in
            defer { subscribers[ref] = buffer }
            return subscribers[ref]
        }
        previous?.finish()
        return AsyncStream { [subscribers] in
            guard let output = await buffer.next() else {
                subscribers.withValue { if $0[ref] === buffer { $0[ref] = nil } }
                return nil
            }
            return output
        }
    }

    /// Dropped when nobody is watching. False when the subscriber fell
    /// behind and its backlog was dropped: the sender must resync.
    @discardableResult
    public func send(_ output: TerminalOutput, to ref: AgentRef) -> Bool {
        subscribers.value[ref]?.append(output) ?? true
    }
}

/// One subscriber's pending output: a reset flag and coalesced bytes.
final class TerminalOutputBuffer: Sendable {
    private struct Pending {
        var needsReset = false
        var bytes = Data()
        var isFinished = false
        var waiter: CheckedContinuation<TerminalOutput?, Never>?

        /// Takes what is pending, or nil when nothing is.
        mutating func take() -> TerminalOutput? {
            if needsReset {
                needsReset = false
                return .reset
            }
            guard !bytes.isEmpty else { return nil }
            defer { bytes = Data() }
            return .bytes(bytes)
        }
    }

    private let cap: Int
    private let state = LockIsolated(Pending())

    init(cap: Int) { self.cap = cap }

    func append(_ output: TerminalOutput) -> Bool {
        let (waiter, isKept): (CheckedContinuation<TerminalOutput?, Never>?, Bool) = state.withValue { pending in
            guard !pending.isFinished else { return (nil, true) }
            switch output {
            case .reset:
                pending.needsReset = true
                pending.bytes = Data()
            case .bytes(let data):
                guard pending.bytes.count + data.count <= cap else {
                    pending.bytes = Data()
                    return (nil, false)
                }
                pending.bytes.append(data)
            }
            guard let waiter = pending.waiter else { return (nil, true) }
            pending.waiter = nil
            return (waiter, true)
        }
        waiter?.resume(returning: state.withValue { $0.take() })
        return isKept
    }

    func finish() {
        let waiter = state.withValue { pending in
            pending.isFinished = true
            defer { pending.waiter = nil }
            return pending.waiter
        }
        waiter?.resume(returning: nil)
    }

    /// The pending output, waiting for some; nil once finished or cancelled.
    func next() async -> TerminalOutput? {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let ready: TerminalOutput?? = state.withValue { pending in
                    if let output = pending.take() { return .some(output) }
                    if pending.isFinished || Task.isCancelled { return .some(nil) }
                    pending.waiter = continuation
                    return nil
                }
                if let ready { continuation.resume(returning: ready) }
            }
        } onCancel: {
            finish()
        }
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
