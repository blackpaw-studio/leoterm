import Foundation

/// `~/.leo/state/managed.json`: the contract by which the app tells leo it
/// owns the daemon. leo ignores a marker it can't validate, so the writer
/// only ever emits absolute paths. `selfPath` is persisted exactly as given
/// (the `~/.leo/app/bin/leo` link, never its resolved target) so it survives
/// app updates.
struct LeoManagedMarker: Equatable, Sendable {
    static let schemaVersion = 1
    static let manager = "Leo.app"

    var bundleID: String
    var launchdLabel: String
    var selfPath: String
    var tmuxPath: String
    /// Applied by the daemon on top of its own environment at startup (D5).
    var env: [String: String]?
}

enum LeoMarkerState: Equatable, Sendable {
    case absent
    case ours(LeoManagedMarker)
    /// Written by a different bundle (e.g. the Debug build's marker seen by
    /// Release). Its `selfPath` still resolves for the CLI.
    case foreign(bundleID: String, marker: LeoManagedMarker)
    case invalid(String)
}

enum LeoMarkerError: Error, Equatable, Sendable {
    case relativePath(field: String, value: String)
    case missingField(String)
}

extension LeoManagedMarker {
    func encoded() throws -> Data {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(Wire(
            version: Self.schemaVersion, manager: Self.manager, bundleID: bundleID, launchdLabel: launchdLabel,
            selfPath: selfPath, tmuxPath: tmuxPath, env: env
        ))
    }

    static func decode(_ data: Data, ownBundleID: String) -> LeoMarkerState {
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data) else { return .invalid("malformed JSON") }
        guard wire.version == schemaVersion else { return .invalid("unsupported version \(wire.version)") }
        let marker = Self(
            bundleID: wire.bundleID ?? "", launchdLabel: wire.launchdLabel ?? "",
            selfPath: wire.selfPath ?? "", tmuxPath: wire.tmuxPath ?? "", env: wire.env
        )
        do {
            try marker.validate()
        } catch let LeoMarkerError.missingField(field) {
            return .invalid("missing \(field)")
        } catch let LeoMarkerError.relativePath(field, value) {
            return .invalid("\(field) must be absolute: \(value)")
        } catch {
            return .invalid("\(error)")
        }
        return marker.bundleID == ownBundleID ? .ours(marker) : .foreign(bundleID: marker.bundleID, marker: marker)
    }

    func validate() throws {
        for (field, value) in [("bundle_id", bundleID), ("launchd_label", launchdLabel)] where value.isEmpty {
            throw LeoMarkerError.missingField(field)
        }
        for (field, value) in [("self_path", selfPath), ("tmux_path", tmuxPath)] {
            if value.isEmpty { throw LeoMarkerError.missingField(field) }
            if !value.hasPrefix("/") { throw LeoMarkerError.relativePath(field: field, value: value) }
        }
    }

    private struct Wire: Codable {
        var version: Int
        var manager: String?
        var bundleID: String?
        var launchdLabel: String?
        var selfPath: String?
        var tmuxPath: String?
        var env: [String: String]?

        enum CodingKeys: String, CodingKey {
            case version, manager, env
            case bundleID = "bundle_id"
            case launchdLabel = "launchd_label"
            case selfPath = "self_path"
            case tmuxPath = "tmux_path"
        }
    }
}
