import Foundation
import LeoKit

struct LeoCLI: Sendable {
    let executableOverride: String?
    let runner: any LeoProcessRunning
    let candidatePaths: [String]
    let path: String?
    /// The helper inside Leo.app, tried last (D6). nil outside a bundle.
    let bundledExecutable: String?
    /// The managed-install marker; its `self_path` is tried right after the override.
    let markerState: @Sendable () -> LeoMarkerState
    let expandTilde: @Sendable (String) -> String
    let isExecutable: @Sendable (String) -> Bool

    init(
        executableOverride: String? = nil,
        runner: any LeoProcessRunning,
        candidatePaths: [String] = ["~/.local/bin/leo"],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        bundledExecutable: String? = LeoInstallPaths.live().bundledLeo.path,
        markerState: @escaping @Sendable () -> LeoMarkerState = Self.liveMarkerState,
        expandTilde: @escaping @Sendable (String) -> String = { NSString(string: $0).expandingTildeInPath },
        isExecutable: @escaping @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) {
        self.executableOverride = executableOverride
        self.runner = runner
        self.candidatePaths = candidatePaths
        self.path = path
        self.bundledExecutable = bundledExecutable
        self.markerState = markerState
        self.expandTilde = expandTilde
        self.isExecutable = isExecutable
    }

    /// Reads (never writes) the real marker for this app's bundle identifier.
    @Sendable static func liveMarkerState() -> LeoMarkerState {
        LeoMarkerStore(paths: .live(), fileSystem: LeoDiskFileSystem(), bundleID: Bundle.main.bundleIdentifier ?? "").read()
    }

    /// Non-override lookup order (D6): managed `self_path` (ours or foreign),
    /// `~/.local/bin/leo`, `PATH`, then the bundled helper. First occurrence wins.
    var candidateExecutables: [String] {
        Self.candidates(
            markerState: markerState(), candidatePaths: candidatePaths, path: path,
            bundledExecutable: bundledExecutable, expandTilde: expandTilde
        )
    }

    func resolveExecutable() throws -> String {
        try Self.resolveExecutable(
            executableOverride: executableOverride, candidatePaths: candidatePaths, path: path,
            bundledExecutable: bundledExecutable, markerState: markerState(), expandTilde: expandTilde, isExecutable: isExecutable
        )
    }

    static func candidates(
        markerState: LeoMarkerState = .absent,
        candidatePaths: [String] = ["~/.local/bin/leo"],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        bundledExecutable: String? = nil,
        expandTilde: @Sendable (String) -> String = { NSString(string: $0).expandingTildeInPath }
    ) -> [String] {
        let managed: [String] = switch markerState {
        case let .ours(marker), let .foreign(_, marker): [marker.selfPath]
        case .absent, .invalid: []
        }
        let ordered = managed
            + candidatePaths.map(expandTilde)
            + (path?.split(separator: ":").map { "\($0)/leo" } ?? [])
            + (bundledExecutable.map { [$0] } ?? [])
        var seen = Set<String>()
        return ordered.filter { seen.insert($0).inserted }
    }

    static func resolveExecutable(
        executableOverride: String? = nil,
        candidatePaths: [String] = ["~/.local/bin/leo"],
        path: String? = ProcessInfo.processInfo.environment["PATH"],
        bundledExecutable: String? = nil,
        markerState: LeoMarkerState = .absent,
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

        let candidates = candidates(
            markerState: markerState, candidatePaths: candidatePaths, path: path,
            bundledExecutable: bundledExecutable, expandTilde: expandTilde
        )
        if let executable = candidates.first(where: isExecutable) { return executable }
        throw LeoDaemonError.transport("leo executable not found; tried: \(candidates.joined(separator: ", "))")
    }

    func templateList() async throws -> [LeoTemplate] {
        try decode(try await run(["template", "list", "--json"]), as: [LeoTemplate].self)
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
