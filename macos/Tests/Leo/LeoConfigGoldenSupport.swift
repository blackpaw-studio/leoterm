import Foundation

@testable import LeoKit

/// A `LeoFakeConfigClient` seeded with the daemon's golden bodies (the same
/// files LeoKit's tests decode), so a pane model is tested against real shapes.
enum LeoConfigGolden {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/LeoKit/Tests/LeoKitTests/Fixtures/config/golden")

    private static func decode<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
        let body = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return try LeoDaemonEnvelope<T>.decode(body).value()
    }

    static func schema() throws -> LeoConfigSchema {
        try decode(LeoConfigSchema.self, "schema")
    }

    /// The golden `coder` template, whose `env` also holds a secret variable.
    static func coderWithSecretEnv() throws -> LeoConfigItem {
        try decode(LeoConfigWriteResult.self, "put_template_env_secret").item?.item ?? LeoConfigItem(name: "coder", values: [:])
    }

    /// The golden `base` environment plus a second one, `work`, whose `env` also holds a secret variable.
    static func environmentsWithSecret() throws -> [LeoConfigItem] {
        try decode(LeoConfigCollection.self, "environments").items + [
            LeoConfigItem(name: "work", values: ["env": .object(["WORK_TOKEN": .secret(isSet: true), "WORK_URL": .string("http://work.local")])]),
        ]
    }

    static func client(
        supported: Bool = true, secretEnv: Bool = false, secretEnvironment: Bool = false, tasks: LeoFakeTaskData = LeoFakeTaskData(),
        delegation: LeoDelegationDocument? = nil
    ) throws -> LeoFakeConfigClient {
        func items(_ name: String) throws -> [LeoConfigItem] { try decode(LeoConfigCollection.self, name).items }
        func singleton(_ name: String) throws -> LeoConfigItem { try decode(LeoConfigDocument.self, name).item }
        return LeoFakeConfigClient(
            schema: try schema(),
            singletons: ["defaults": try singleton("defaults"), "web": try singleton("web"), "client": try singleton("client")],
            collections: [
                "templates": try items("templates").map { secretEnv && $0.name == "coder" ? try coderWithSecretEnv() : $0 },
                "tasks": try items("tasks"),
                "environments": secretEnvironment ? try environmentsWithSecret() : try items("environments"), "hosts": try items("hosts"),
            ],
            tasks: tasks, delegation: delegation,
            version: LeoDaemonVersionInfo(version: "0.52.0", capabilities: supported ? [LeoConfigAPI.capability] : [])
        )
    }

    /// The golden tasks' runs, logs and prompt files: `heartbeat` has three runs
    /// (the newest failed, with a truncated log, and one left no log) and a
    /// prompt, `nightly`'s prompt file doesn't exist yet.
    static func taskData(protectedPrompts: Set<String> = []) -> LeoFakeTaskData {
        func run(_ second: Int, exit: Int? = 0, log: String? = nil) -> LeoTaskRun {
            LeoTaskRun(
                task: "heartbeat", startedAt: Date(timeIntervalSince1970: 1_792_742_400 + Double(second) * 60), exitCode: exit, durationMs: 1500,
                logFile: log ?? "heartbeat-\(second).jsonl"
            )
        }
        return LeoFakeTaskData(
            runs: ["heartbeat": [run(300, exit: 1), run(200, log: ""), run(100)]],
            logs: ["heartbeat-300.jsonl": "boom\n", "heartbeat-100.jsonl": "fine\n"], truncatedLogs: ["heartbeat-300.jsonl"],
            prompts: ["heartbeat.md": "Check the thing.\n", "notes.md": "Notes\n"], protectedPrompts: protectedPrompts
        )
    }
}
