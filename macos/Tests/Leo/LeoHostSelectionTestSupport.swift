import Foundation
import Testing

@testable import Ghostty

/// Shared helpers for `LeoHostSelectionTests`/`LeoHostSelectionRaceTests`.
enum LeoHostSelectionTestSupport {
    static let localSocketPath = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath

    @MainActor static func makeSelection(
        hosts: [LeoHostConfiguration] = [],
        transport: any LeoDaemonTransport = LeoAlwaysHealthyTransport(),
        runner: any LeoProcessRunning = LeoProcessRunner(),
        defaults: UserDefaults? = nil,
        orphanStore: LeoTunnelOrphanStore? = nil
    ) -> LeoHostSelection {
        let defaults = defaults ?? (UserDefaults(suiteName: "LeoHostSelectionTests.\(UUID().uuidString)") ?? .standard)
        if let data = try? JSONEncoder().encode(hosts) { defaults.set(data, forKey: LeoHostStore.key) }
        return LeoHostSelection(
            store: LeoHostStore(defaults: defaults),
            defaults: defaults,
            runner: runner,
            sshExecutable: LeoTunnelTestSupport.fixtureURL(),
            transport: transport,
            orphanStore: orphanStore,
            localSocketPath: localSocketPath
        )
    }

    static func expectedLocalSocketPath(_ configuration: LeoHostConfiguration) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("leoterm", isDirectory: true)
            .appendingPathComponent(configuration.localSocketFileName)
            .path
    }

    static func tempFile() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent("lhs-\(UUID().uuidString.prefix(8))").path
    }

    static func readPID(_ path: String) throws -> Int32 {
        let text = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(Int32(text))
    }

    /// `LeoAlwaysHealthyTransport` answers `/health` unconditionally, so
    /// `LeoTunnel`'s readiness loop can resolve before the just-forked
    /// `fake_ssh.py` child has actually reached its own pid-file write --
    /// wait for the file itself, not just `.connected`, before reading it.
    static func awaitPID(_ path: String) async throws -> Int32 {
        await awaitCondition(message: "pid file was never written") { FileManager.default.fileExists(atPath: path) }
        return try readPID(path)
    }

    @MainActor static func awaitConnected(_ selection: LeoHostSelection, _ path: String) async {
        await awaitCondition(message: "never reached .connected(\(path))") {
            await selection.state == .connected(socketPath: path)
        }
    }

    @MainActor static func awaitFailed(_ selection: LeoHostSelection) async {
        await awaitCondition(message: "never reached .failed") {
            let state = await selection.state
            return isFailed(state)
        }
    }

    static func isFailed(_ state: LeoHostConnectionState) -> Bool {
        if case .failed = state { return true }
        return false
    }
}

/// Always answers `/health` with 200 immediately -- used by tests that don't
/// care about probe timing.
struct LeoAlwaysHealthyTransport: LeoDaemonTransport {
    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        LeoHTTPResponse(status: 200, body: Data())
    }
}

/// Parks every `/health` call until `open()` is called, at which point every
/// pending AND future call resolves successfully. Cancellation-aware: a
/// probe `Task` cancelled while parked (e.g. because `LeoTunnel.start()` was
/// interrupted by `terminateAndWait()`) resumes with `CancellationError`
/// instead of leaking a continuation forever.
actor LeoGatedTransport: LeoDaemonTransport {
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func send(_: LeoHTTPRequest, socketPath _: String, timeout _: TimeInterval) async throws -> LeoHTTPResponse {
        if !isOpen {
            let id = UUID()
            try await withTaskCancellationHandler(
                operation: {
                    try await withCheckedThrowingContinuation { waiters[id] = $0 }
                },
                onCancel: { Task { await self.cancelWaiter(id) } }
            )
        }
        return LeoHTTPResponse(status: 200, body: Data())
    }

    private func cancelWaiter(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    func open() {
        isOpen = true
        waiters.values.forEach { $0.resume() }
        waiters = [:]
    }
}

actor LeoFakeHomeRunner: LeoProcessRunning {
    private(set) var calls: [(executable: String, arguments: [String])] = []
    let stdout: String

    init(stdout: String) { self.stdout = stdout }

    func run(executable: String, arguments: [String], timeout _: TimeInterval) async throws -> LeoProcessResult {
        calls.append((executable, arguments))
        return LeoProcessResult(stdout: Data(stdout.utf8), stderr: Data(), status: 0)
    }
}
