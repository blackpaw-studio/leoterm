import Foundation
import os

/// A running `leo host forward` process: streams its stdout lines and lets the
/// caller tear it down. Abstracted so `LeoForwardManager` can be tested without
/// spawning a real `ssh`/`leo` process.
protocol ForwardHandle: Sendable {
    var lines: AsyncStream<String> { get }
    func terminate()
}

/// Launches `leo host forward …`. Injected into `LeoForwardManager`; the
/// production implementation is `ProcessForwardLauncher`.
protocol ForwardLauncher: Sendable {
    func launch(args: [String]) async -> ForwardHandle
}

/// Owns a persistent SSH socket forward to one remote leo host.
///
/// `leo host forward <name> --json` establishes a ControlMaster + a
/// StreamLocalForward of the remote daemon socket to a local path, then blocks.
/// Its contract: the local socket path arrives on the first stdout line once
/// the forward is healthy; the process exiting before that means setup failed.
/// We keep the process alive for the forward's lifetime and `terminate()` it on
/// teardown.
actor LeoForwardManager {
    /// Decode the local socket path from a `leo host forward --json` stdout
    /// line. Returns `nil` for non-JSON / pre-connect log lines.
    static func parseSocketPath(jsonLine: String) -> String? {
        guard let data = jsonLine.data(using: .utf8),
              let line = try? JSONDecoder().decode(ForwardLine.self, from: data)
        else { return nil }
        return line.socket
    }

    static func forwardArgs(host: String) -> [String] { ["host", "forward", host, "--json"] }
    /// Args for an explicit `leo host forward <name> --stop`. Reserved as a
    /// graceful-teardown fallback: `stop()` currently SIGTERMs the foreground
    /// forward process instead (leo's documented "kill to tear down" model).
    /// Switch `stop()` to invoke this if live testing shows SIGTERM leaves a
    /// stale ControlMaster or socket behind.
    static func stopArgs(host: String) -> [String] { ["host", "forward", host, "--stop"] }

    let host: String
    private let launcher: ForwardLauncher
    private var handle: ForwardHandle?

    init(host: String, launcher: ForwardLauncher = ProcessForwardLauncher()) {
        self.host = host
        self.launcher = launcher
    }

    /// Start the forward and resolve to the local socket path once healthy.
    /// Throws if the process ends before printing a socket path.
    func start() async throws(LeoError) -> String {
        let handle = await launcher.launch(args: Self.forwardArgs(host: host))
        self.handle = handle
        for await line in handle.lines {
            if let socket = Self.parseSocketPath(jsonLine: line) { return socket }
        }
        // Stream ended without a socket line: the forward never came up.
        self.handle = nil
        throw LeoError.daemonUnreachable
    }

    /// Tear down the forward by SIGTERM-ing the `leo host forward` process.
    /// leo's process is expected to clean up its own ControlMaster + local
    /// socket on exit ("kill to tear down"); that self-cleanup is the one
    /// teardown behavior that still needs live verification against a real
    /// host (see `stopArgs` for the explicit `--stop` fallback).
    func stop() {
        handle?.terminate()
        handle = nil
    }

    private struct ForwardLine: Decodable { let socket: String? }
}

/// Production `ForwardLauncher`: runs the real `leo host forward` and streams
/// its stdout line-by-line.
struct ProcessForwardLauncher: ForwardLauncher {
    let leoExecutable: String

    init(leoExecutable: String = NSString(string: "~/.local/bin/leo").expandingTildeInPath) {
        self.leoExecutable = leoExecutable
    }

    func launch(args: [String]) async -> ForwardHandle {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: leoExecutable)
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()

        let (stream, continuation) = AsyncStream<String>.makeStream()
        let box = ProcessBox(proc)
        proc.terminationHandler = { _ in continuation.finish() }

        do {
            try proc.run()
        } catch {
            continuation.finish()
            return ProcessForwardHandle(lines: stream, box: box)
        }

        // Forward stdout lines until the pipe closes (process exits).
        Task.detached {
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    continuation.yield(line)
                }
            } catch {}
            continuation.finish()
        }
        return ProcessForwardHandle(lines: stream, box: box)
    }
}

/// `ForwardHandle` backed by a real `Process`.
private struct ProcessForwardHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let box: ProcessBox
    func terminate() { box.terminate() }
}

/// Guards a non-`Sendable` `Process` so it can cross isolation boundaries for
/// the sole purpose of termination.
private final class ProcessBox: @unchecked Sendable {
    private let process: Process
    private let lock = NSLock()

    init(_ process: Process) { self.process = process }

    func terminate() {
        lock.withLock { if process.isRunning { process.terminate() } }
    }
}
