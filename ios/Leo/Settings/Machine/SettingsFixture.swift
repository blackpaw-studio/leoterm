#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// Two scripted machines for the settings screenshots (`-settingsFixture`):
/// Dionysus on leo 0.59.0 with the config API, backed by an in-memory daemon
/// seeded with templates, environments, tasks and a service; and leo-vm on
/// 0.58.0, which shows the "Requires" note. No daemon is needed.
///
/// `-settingsFixtureWrite conflict|invalid` makes Dionysus refuse its next
/// write as a stale revision or a rejected `model` value. The fixture
/// replaces the paired-daemon store, so don't combine it with
/// `-resetForUITests`.
enum SettingsFixture {
    static var isRequested: Bool { ProcessInfo.processInfo.arguments.contains("-settingsFixture") }

    private static let dionysusID = "fixture-Dionysus"

    private static func daemon(_ name: String, _ host: String) -> PairedDaemon {
        PairedDaemon(
            id: "fixture-\(name)", name: name, baseURL: URL(string: "https://\(host)")!, urls: [],
            deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
        )
    }

    private static let daemons = [daemon("Dionysus", "dionysus.lan"), daemon("leo-vm", "192.168.64.7")]

    // MARK: the daemon's config

    private struct Envelope<Value: Decodable>: Decodable {
        let data: Value
    }

    /// The daemon's golden schema, with the field types the golden templates
    /// leave out added to Templates: a secret, a multiline string, YAML, and a
    /// type this app doesn't know.
    private static func schema() -> LeoConfigSchema {
        let golden = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Packages/LeoKit/Tests/LeoKitTests/Fixtures/config/golden/schema.json")
        func field(_ key: String, _ label: String, _ type: String, extra: [String: Any] = [:]) -> [String: Any] {
            [
                "advanced": false, "constraints": [String: Any](), "default": NSNull(), "group": "Extras", "help": "", "key": key,
                "label": label, "restart": "agents", "type": type, "warning": "",
            ].merging(extra) { _, new in new }
        }
        do {
            var root = try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: Any] ?? [:]
            var data = root["data"] as? [String: Any] ?? [:]
            var resources = data["resources"] as? [[String: Any]] ?? []
            if let index = resources.firstIndex(where: { $0["key"] as? String == "templates" }) {
                var fields = resources[index]["fields"] as? [[String: Any]] ?? []
                fields += [
                    field("instructions", "Instructions", "string", extra: ["multiline": true, "help": "Added to the agent's system prompt."]),
                    field("api_key", "API key", "secret", extra: ["help": "The token this template's tools use."]),
                    field("overrides", "Overrides", "yaml"),
                    field("sandbox_profile", "Sandbox profile", "sandbox_profile_v2"),
                ]
                resources[index]["fields"] = fields
            }
            data["resources"] = resources
            root["data"] = data
            return try JSONDecoder().decode(Envelope<LeoConfigSchema>.self, from: JSONSerialization.data(withJSONObject: root)).data
        } catch {
            fatalError("SettingsFixture: the golden schema didn't load: \(error)")
        }
    }

    private static func list(_ values: String...) -> LeoConfigValue { .list(values.map(LeoConfigValue.string)) }

    private static let templates = [
        LeoConfigItem(
            name: "coder",
            values: [
                "workspace": .string("~/work/leo"), "harness": .string("claude"), "model": .string("opus"), "max_turns": .int(80),
                "channels": list("plugin:telegram"), "dev_channels": list(), "mcp_config": .string(""),
                "add_dirs": list("~/work/shared", "~/notes"), "environments": list("work"),
                "env": .map(["EDITOR": "vim", "LANG": "en_US.UTF-8"]), "idle_suspend_after": .string("30m"), "isolation": .string("worktree"),
                "harness_options": .object(["permission_mode": .string("plan"), "bypass_permissions": .bool(false)]),
                "permissions": .object(["can_spawn": list("reviewer"), "can_message": list("scout-*"), "deny_tools": list("leo_stop_agent"), "can_consult": list()]),
                "push": .object(["needs_input": .bool(true), "finished": .null, "errored": .bool(true), "chat": .null]),
                "instructions": .string("Work in small commits.\nRun the tests before you say you are done."),
                "api_key": .secret(isSet: true), "overrides": .string("model: opus\nretries: 2"), "sandbox_profile": .string("strict"),
            ],
            effectiveHarness: "claude"
        ),
        LeoConfigItem(
            name: "reviewer",
            values: [
                "workspace": .string("~/work/leo"), "harness": .string(""), "model": .string("sonnet"), "max_turns": .null,
                "environments": list(), "env": .map([:]), "isolation": .string(""), "api_key": .secret(isSet: false),
            ],
            inherited: ["harness": .string("claude")], effectiveHarness: "claude"
        ),
        LeoConfigItem(
            name: "scout",
            values: ["workspace": .string("~/scratch"), "harness": .string("codex"), "model": .string("gpt-5"), "environments": list("work", "staging")],
            effectiveHarness: "codex"
        ),
    ]

    private static let environments = [
        LeoConfigItem(name: "base", values: ["env": .map(["TZ": "America/New_York", "LOG_LEVEL": "info"])]),
        LeoConfigItem(name: "staging", values: ["env": .map(["API_URL": "https://staging.example.com", "FEATURE_FLAGS": "beta,new-ui"])]),
        LeoConfigItem(name: "work", values: ["env": .map([
            "API_URL": "https://api.example.com", "AWS_PROFILE": "work", "HTTP_PROXY": "http://proxy.corp:3128", "REGION": "us-east-1",
        ])]),
    ]

    private static let tasks = [
        LeoConfigItem(
            name: "heartbeat",
            values: [
                "enabled": .bool(true), "schedule": .string("0 * * * *"), "timezone": .string("America/New_York"),
                "prompt_file": .string("heartbeat.md"), "template": .string("coder"), "runtime": .string("oneshot"),
                "timeout": .string("10m"), "retries": .int(1), "silent": .bool(false), "notify_on_fail": .bool(true),
                "environments": list("work"), "env": .map([:]),
            ],
            inherited: ["model": .string("sonnet")], effectiveHarness: "claude"
        ),
        LeoConfigItem(
            name: "nightly",
            values: [
                "enabled": .bool(false), "schedule": .string("30 2 * * *"), "timezone": .string("America/New_York"),
                "prompt_file": .string("prompts/nightly.md"), "template": .string("reviewer"), "runtime": .string("oneshot"),
                "timeout": .string("1h"), "silent": .bool(true), "environments": list(), "env": .map(["NIGHTLY": "1"]),
            ],
            effectiveHarness: "claude"
        ),
        LeoConfigItem(
            name: "weekly-report",
            values: [
                "enabled": .bool(true), "schedule": .string("0 9 * * 1"), "timezone": .string("America/New_York"),
                "prompt_file": .string("prompts/weekly.md"), "template": .string("scout"), "environments": list("base"), "env": .map([:]),
            ],
            effectiveHarness: "codex"
        ),
    ]

    private static func runs(_ task: String, exits: [Int?]) -> [LeoTaskRun] {
        exits.enumerated().map { index, exit in
            LeoTaskRun(
                task: task, startedAt: Date().addingTimeInterval(TimeInterval(-3_600 * (index + 1))), exitCode: exit,
                durationMs: exit == nil ? nil : 42_000 + index * 9_000, logFile: "\(task)-\(index).log"
            )
        }
    }

    private static let dionysus: LeoFakeConfigClient = {
        let log = """
        2026-10-24 09:00:01 starting heartbeat
        2026-10-24 09:00:02 agent coder: checking in
        2026-10-24 09:00:11 3 messages waiting, 0 need input
        2026-10-24 09:00:42 done (exit 0)
        """
        let client = LeoFakeConfigClient(
            schema: schema(),
            collections: ["templates": templates, "environments": environments, "tasks": tasks],
            tasks: LeoFakeTaskData(
                runs: ["heartbeat": runs("heartbeat", exits: [0, 0, 1, 0]), "nightly": runs("nightly", exits: [0, nil])],
                logs: ["heartbeat-0.log": log, "heartbeat-1.log": log, "heartbeat-2.log": "agent coder: exited with status 1\n", "heartbeat-3.log": log],
                prompts: [
                    "heartbeat.md": "Check in on the other agents.\nSummarize anything that needs a human, then stop.\n",
                    "prompts/nightly.md": "Review the day's merged work and file follow-ups.\n",
                    "prompts/weekly.md": "Write the weekly report from the task history.\n",
                ]
            ),
            version: LeoDaemonVersionInfo(version: "0.59.0", capabilities: [LeoConfigAPI.capability])
        )
        Task {
            await client.setService(LeoFakeServiceState(
                version: "v0.59.0", pid: 4_182, startedAt: Date().addingTimeInterval(-86_400 * 3),
                processes: [
                    LeoServiceProcess(name: "coder", status: "running", startedAt: Date().addingTimeInterval(-7_200)),
                    LeoServiceProcess(name: "reviewer", status: "running", startedAt: Date().addingTimeInterval(-600)),
                    LeoServiceProcess(name: "scout", status: "stopped"),
                ],
                log: (0..<40).map { "2026-10-24 09:\(String(format: "%02d", $0)):00 supervisor: tick \($0), 2 agents running" }.joined(separator: "\n")
            ))
        }
        return client
    }()

    /// What a launch argument makes the first write fail with.
    private static func scriptedWriteFailure() -> (any Error)? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-settingsFixtureWrite"), arguments.indices.contains(flag + 1) else { return nil }
        switch arguments[flag + 1] {
        case "conflict": return LeoConfigError.conflict(currentRevision: "sha256:fixture-newer")
        case "invalid": return LeoConfigError.invalid([LeoConfigFieldError(field: "model", message: "unknown model \"opus-9\"")])
        default: return nil
        }
    }

    // MARK: the app's dependencies

    /// Replaces the paired daemons, keychain, daemon transport and config client.
    static func prepare(_ values: inout DependencyValues) {
        values.pairedDaemons.load = { daemons }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.events = { connection in
            AsyncThrowingStream { continuation in
                if connection.daemonID == dionysusID {
                    continuation.yield(.hello(seq: 1, at: nil, version: "0.59.0", serverTime: nil, features: ["config_api", "machine_stats"]))
                } else {
                    continuation.yield(.hello(seq: 1, at: nil, version: "0.58.0", serverTime: nil, features: ["machine_stats"]))
                }
            }
        }
        values.daemonClient.fetchState = { _ in
            LeoObservedState(agents: ["coder", "reviewer"].map {
                LeoObservedAgent(name: $0, status: .running, activity: .idle, currentAction: nil, lastActivityAt: nil, attention: nil, startedAt: nil, template: "coder", harness: "claude")
            })
        }
        values.daemonClient.machineStats = { _ in
            LeoMachineStats(
                sampledAt: Date(), cpu: .init(percent: 23, cores: 8),
                memory: .init(usedBytes: 850, totalBytes: 1_000), disk: .init(path: "/", usedBytes: 470, totalBytes: 1_000)
            )
        }
        let client = dionysus
        if let failure = scriptedWriteFailure() { Task { await client.failNextWrite(with: failure) } }
        values.configClients = ConfigClients(client: { _ in client })
    }

    /// Opens the Machines screen once the app has launched.
    @MainActor static func openMachines(_ store: StoreOf<AppFeature>) {
        store.send(.daemonsButtonTapped)
    }
}
#endif
