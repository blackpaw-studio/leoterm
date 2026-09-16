import Foundation

struct LeoCLI: Sendable {
    let executableOverride: String?
    let runner: any LeoProcessRunning
    let candidatePaths: [String]
    let path: String?
    let expandTilde: @Sendable (String) -> String
    let isExecutable: @Sendable (String) -> Bool

    init(
        executableOverride: String? = nil,
        runner: any LeoProcessRunning = LeoProcessRunner(),
        candidatePaths: [String] = ["~/.local/bin/leo"],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        expandTilde: @escaping @Sendable (String) -> String = { NSString(string: $0).expandingTildeInPath },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.executableOverride = executableOverride
        self.runner = runner
        self.candidatePaths = candidatePaths
        self.path = path
        self.expandTilde = expandTilde
        self.isExecutable = isExecutable
    }

    func resolveExecutable() throws -> String {
        try Self.resolveExecutable(executableOverride: executableOverride, candidatePaths: candidatePaths, path: path, expandTilde: expandTilde, isExecutable: isExecutable)
    }

    static func resolveExecutable(
        executableOverride: String? = nil,
        candidatePaths: [String] = ["~/.local/bin/leo"],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        expandTilde: @Sendable (String) -> String = { NSString(string: $0).expandingTildeInPath },
        isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) throws -> String {
        if let executableOverride {
            let expanded = expandTilde(executableOverride)
            guard isExecutable(expanded) else {
                throw LeoDaemonError.transport("leo executable is not executable: \(expanded)")
            }
            return expanded
        }

        let candidates = candidatePaths.map(expandTilde) + (path?.split(separator: ":").map { "\($0)/leo" } ?? [])
        if let executable = candidates.first(where: isExecutable) { return executable }
        throw LeoDaemonError.transport("leo executable not found; tried: \(candidates.joined(separator: ", "))")
    }

    func templateList() async throws -> [LeoTemplate] {
        try decode(try await run(["template", "list", "--json"]), as: [LeoTemplate].self)
    }

    func hostList() async throws -> [LeoHost] {
        try decode(try await run(["host", "list", "--json"]), as: [LeoHost].self)
    }

    private func run(_ arguments: [String]) async throws -> Data {
        let result = try await runner.run(executable: try resolveExecutable(), arguments: arguments, timeout: 30)
        guard result.status == 0 else {
            throw LeoDaemonError.transport(String(data: result.stderr, encoding: .utf8) ?? "leo exited \(result.status)")
        }
        return result.stdout
    }

    private func decode<T: Decodable>(_ data: Data, as type: T.Type) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LeoDaemonError.decoding(String(describing: error))
        }
    }
}
