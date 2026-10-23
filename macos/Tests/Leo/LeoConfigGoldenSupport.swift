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

    static func client(supported: Bool = true, secretEnv: Bool = false) throws -> LeoFakeConfigClient {
        func items(_ name: String) throws -> [LeoConfigItem] { try decode(LeoConfigCollection.self, name).items }
        func singleton(_ name: String) throws -> LeoConfigItem { try decode(LeoConfigDocument.self, name).item }
        return LeoFakeConfigClient(
            schema: try schema(),
            singletons: ["defaults": try singleton("defaults"), "web": try singleton("web"), "client": try singleton("client")],
            collections: [
                "templates": try items("templates").map { secretEnv && $0.name == "coder" ? try coderWithSecretEnv() : $0 },
                "tasks": try items("tasks"),
                "environments": try items("environments"), "hosts": try items("hosts"),
            ],
            version: LeoDaemonVersionInfo(version: "0.52.0", capabilities: supported ? [LeoConfigAPI.capability] : [])
        )
    }
}
