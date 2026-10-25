import Foundation
import Testing

@testable import LeoKit

/// The config API fixtures in `Fixtures/config`: the daemon's golden bodies
/// (`golden/`, from `TestConfigAPIGolden`) where there is one, else the
/// hand-written Part A body (see its README).
enum LeoConfigFixtures {
    static let names = [
        "schema", "defaults", "templates", "template_coder", "tasks", "environments", "web", "client", "hosts",
        "delegation", "delegation_preview", "prompt", "task_history", "service_status", "version",
        "write_result", "error_409", "error_422",
    ]

    private static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/config")

    /// Every golden file's name, `STATUS` excluded.
    static var goldenNames: [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("golden").path)) ?? []
        return files.filter { $0.hasSuffix(".json") && $0 != "STATUS.json" }.map { String($0.dropLast(".json".count)) }.sorted()
    }

    static func goldenData(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appendingPathComponent("golden/\(name).json"))
    }

    /// The HTTP status the daemon answered a golden body with.
    static func goldenStatus(_ name: String) throws -> Int {
        let body = try goldenData("STATUS")
        let statuses = try JSONDecoder().decode([String: Int].self, from: body)
        return try #require(statuses[name], "STATUS.json has no \(name)")
    }

    static func data(_ name: String) throws -> Data {
        if let golden = try? goldenData(name) { return golden }
        return try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
    }

    /// The `data` payload of a success envelope, as a typed value.
    static func decode<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
        try LeoDaemonEnvelope<T>.decode(try data(name)).value()
    }
}
