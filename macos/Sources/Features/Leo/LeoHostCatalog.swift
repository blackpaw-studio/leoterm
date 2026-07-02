import Foundation

/// Lists the configured leo hosts by running `leo host list --json` and
/// decoding `[LeoHost]`. The synthesized `localhost` entry is always present;
/// the rest are SSH-reachable remotes from `client.hosts` in `leo.yaml`.
///
/// The CLI runner is injected so tests can supply canned stdout without
/// spawning a real process. The default runner invokes the real `leo` binary.
struct LeoHostCatalog: Sendable {
    /// Runs the given `leo` argument list and returns stdout, or throws a
    /// `LeoError` on launch failure / non-zero exit.
    typealias Runner = @Sendable (_ args: [String]) async throws(LeoError) -> Data

    private let runner: Runner

    init(leoExecutable: String = LeoCLI.executablePath) {
        self.runner = { args throws(LeoError) in
            // Run the blocking `Process` off the cooperative thread pool, mirroring
            // `LeoSocketClient.request(_:)`'s continuation + background-queue hop.
            let result: Result<Data, LeoError> = await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try LeoProcessRunner.run(executable: leoExecutable, args: args)
                        continuation.resume(returning: .success(data))
                    } catch let e as LeoError {
                        continuation.resume(returning: .failure(e))
                    } catch {
                        continuation.resume(returning: .failure(LeoError.daemonUnreachable))
                    }
                }
            }
            switch result {
            case .success(let data): return data
            case .failure(let e): throw e
            }
        }
    }

    /// Test seam: inject a runner that returns canned stdout `Data`.
    init(runner: @escaping Runner) {
        self.runner = runner
    }

    /// Fetch the configured hosts via `leo host list --json`.
    func listHosts() async throws(LeoError) -> [LeoHost] {
        let data = try await runner(["host", "list", "--json"])
        do {
            return try JSONDecoder().decode([LeoHost].self, from: data)
        } catch {
            throw LeoError.decode(detail: "host list: \(error)")
        }
    }
}
