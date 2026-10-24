import Foundation
import LeoKit

/// A `LeoFakeConfigClient` seeded with the daemon's golden bodies (the same
/// files LeoKit's tests decode), so a pane's reducer is tested against real shapes.
enum ConfigGolden {
    private static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Packages/LeoKit/Tests/LeoKitTests/Fixtures/config/golden")

    private struct Envelope<Value: Decodable>: Decodable {
        let data: Value
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, _ name: String) throws -> Value {
        let body = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return try JSONDecoder().decode(Envelope<Value>.self, from: body).data
    }

    static func client(supported: Bool = true, tasks: LeoFakeTaskData = LeoFakeTaskData()) throws -> LeoFakeConfigClient {
        func items(_ name: String) throws -> [LeoConfigItem] { try decode(LeoConfigCollection.self, name).items }
        func singleton(_ name: String) throws -> LeoConfigItem { try decode(LeoConfigDocument.self, name).item }
        return LeoFakeConfigClient(
            schema: try decode(LeoConfigSchema.self, "schema"),
            singletons: ["defaults": try singleton("defaults"), "web": try singleton("web"), "client": try singleton("client")],
            collections: [
                "templates": try items("templates"), "tasks": try items("tasks"),
                "environments": try items("environments"), "hosts": try items("hosts"),
            ],
            tasks: tasks,
            version: LeoDaemonVersionInfo(version: "0.59.0", capabilities: supported ? [LeoConfigAPI.capability] : [])
        )
    }
}
