import Foundation

struct LeoCLI: Sendable {
    let executableOverride: String?
    let runner: any LeoProcessRunning

    init(executableOverride: String? = nil, runner: any LeoProcessRunning = LeoProcessRunner()) {
        self.executableOverride = executableOverride
        self.runner = runner
    }

    func resolveExecutable() throws -> String {
        if let executableOverride { return executableOverride }
        let local = NSString(string: "~/.local/bin/leo").expandingTildeInPath
        if FileManager.default.isExecutableFile(atPath: local) { return local }
        let path = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        if let executable = path.map({ "\($0)/leo" }).first(where: FileManager.default.isExecutableFile(atPath:)) { return executable }
        throw LeoDaemonError.transport("leo executable not found")
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
