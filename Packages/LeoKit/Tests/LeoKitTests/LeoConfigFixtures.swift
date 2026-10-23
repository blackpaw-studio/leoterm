import Foundation

@testable import LeoKit

/// The hand-written Part A fixtures in `Fixtures/config` (see its README).
enum LeoConfigFixtures {
    static let names = [
        "schema", "defaults", "templates", "template_coder", "tasks", "environments", "web", "client", "hosts",
        "delegation", "delegation_preview", "prompt", "history", "service_status", "version",
        "write_result", "error_409", "error_422",
    ]

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().appendingPathComponent("Fixtures/config/\(name).json"))
    }

    /// The `data` payload of a success envelope, as a typed value.
    static func decode<T: Decodable & Sendable>(_ type: T.Type, _ name: String) throws -> T {
        try LeoDaemonEnvelope<T>.decode(try data(name)).value()
    }
}
