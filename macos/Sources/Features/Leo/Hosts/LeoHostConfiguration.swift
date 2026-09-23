import CryptoKit
import Foundation

enum LeoHostValidationError: Error, Equatable, Sendable {
    case emptyName
    case reservedName
    case emptySSHTarget
    case malformedPort
    case invalidName
    case unsafeSSHTarget
    case unsafeIdentityFile
    case ipv6NotSupported
}

struct LeoHostConfiguration: Codable, Hashable, Sendable, Identifiable {
    let id: UUID
    let name: String
    let sshTarget: String
    let identityFile: String?
    let remoteLeoPath: String
    let remoteSocketPath: String

    init(
        id: UUID = UUID(),
        name: String,
        sshTarget: String,
        identityFile: String? = nil,
        remoteLeoPath: String = "~/.local/bin/leo",
        remoteSocketPath: String = "~/.leo/state/leo.sock"
    ) {
        self.id = id
        self.name = name
        self.sshTarget = sshTarget
        self.identityFile = identityFile
        self.remoteLeoPath = remoteLeoPath
        self.remoteSocketPath = remoteSocketPath
    }

    var user: String? { parsedTarget.user }
    var host: String { parsedTarget.host }
    var port: Int? { parsedTarget.port }

    /// `<slug ≤24>-<first 12 hex of the uuid>.sock`: where versions before
    /// B-021 bound the forwarded socket, in `~/.leo/state/leoterm/`. Kept
    /// only so a stale socket left there can be found and removed.
    var legacySocketFileName: String {
        let slug = String(name.lowercased().unicodeScalars.map { scalar in
            switch scalar.value {
            case 48...57, 97...122, 45:
                Character(scalar)
            default:
                "_"
            }
        })
        let prefix = slug.isEmpty ? "_" : String(slug.prefix(24))
        return "\(prefix)-\(shortID).sock"
    }

    /// `lt-<instance>-<first 12 hex of the uuid>.sock`: the forwarded daemon
    /// socket, beside the control sockets in `LeoControlSocketDirectory`.
    /// Always 29 bytes, so with the directory's fixed length the path fits
    /// the AF_UNIX limit for every user or for none. Scoped to the app
    /// bundle like the control socket (both apps share the directory) and
    /// keyed by id, so a reconnect finds the same path and a rename doesn't
    /// move it. 12 hex digits (48 bits) of a UUIDv4 is collision-proof for
    /// any realistic hosts list.
    func tunnelSocketFileName(instance: String) -> String {
        "lt-\(instance)-\(shortID).sock"
    }

    /// `cm-<instance>-<first 12 hex of the uuid>-<connection>`: the tunnel's
    /// ControlMaster socket, in `LeoControlSocketDirectory`. `instance` scopes
    /// it to one app bundle (`controlSocketInstance(bundleIdentifier:)`),
    /// since the debug and production apps share the socket directory and
    /// must never touch each other's master. Keyed by id, not name (renaming
    /// a host must not orphan its master). `connection` hashes the app's own
    /// argv inputs that pick the server (`connectionFingerprint`): a master
    /// a crashed app left running is reused by the next tunnel, so a host
    /// whose target, user, port or identity changed since must land on a
    /// new path rather than send file access to the old server. It does not
    /// see `~/.ssh/config`: repointing an alias's `HostName` there keeps the
    /// path, and a master still running reaches the old server until the
    /// tunnel restarts. Kept short because ssh binds a temporary
    /// `<path>.<16 random chars>` first, so the path gets 17 bytes less of
    /// the AF_UNIX limit than the forwarded socket does.
    func controlSocketFileName(instance: String) -> String {
        "cm-\(instance)-\(shortID)-\(connectionFingerprint)"
    }

    private var shortID: String {
        String(id.uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(12))
    }

    /// The first 8 hex digits of the bundle identifier's SHA-256: short,
    /// stable across launches, and path-safe whatever the identifier is.
    static func controlSocketInstance(bundleIdentifier: String) -> String {
        Self.shortHash(Data(bundleIdentifier.utf8))
    }

    /// 8 hex digits of the SHA-256 of the argv inputs `LeoSSHCommand` passes
    /// ssh to choose the server -- host, user, port, identity file. Not
    /// what ssh_config resolves them to: an alias hashes as the alias.
    /// Each field is length-prefixed and nil is distinct from empty, so no
    /// two different settings encode alike.
    var connectionFingerprint: String {
        let fields = [host, user, port.map(String.init), identityFile]
        let encoded = fields.map { $0.map { "\($0.utf8.count):\($0)" } ?? "-" }.joined(separator: "\n")
        return Self.shortHash(Data(encoded.utf8))
    }

    private static func shortHash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    func validate() -> [LeoHostValidationError] {
        var errors: [LeoHostValidationError] = []
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append(.emptyName)
        }
        if name.caseInsensitiveCompare("localhost") == .orderedSame {
            errors.append(.reservedName)
        }
        if name.contains("/") || name.contains("\0") {
            errors.append(.invalidName)
        }
        if sshTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || host.isEmpty {
            errors.append(.emptySSHTarget)
        }
        if parsedTarget.isIPv6 {
            errors.append(.ipv6NotSupported)
        }
        if parsedTarget.hasMalformedPort {
            errors.append(.malformedPort)
        }
        if parsedTarget.hasUnsafeComponent {
            errors.append(.unsafeSSHTarget)
        }
        if identityFile?.hasPrefix("-") == true {
            errors.append(.unsafeIdentityFile)
        }
        return errors
    }

    private var parsedTarget: ParsedTarget { ParsedTarget(sshTarget) }
}

private struct ParsedTarget {
    let user: String?
    let host: String
    let port: Int?
    let hasMalformedPort: Bool
    let isIPv6: Bool
    let hasUnsafeComponent: Bool

    init(_ target: String) {
        let target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        let userAndHost = target.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        let hostAndPort: String
        let containsEmptyUser: Bool
        if userAndHost.count == 2 {
            user = userAndHost[0].isEmpty ? nil : String(userAndHost[0])
            hostAndPort = String(userAndHost[1])
            containsEmptyUser = userAndHost[0].isEmpty
        } else {
            user = nil
            hostAndPort = target
            containsEmptyUser = false
        }

        isIPv6 = target.contains("[") || target.contains("]") || target.filter { $0 == ":" }.count > 1

        if let separator = hostAndPort.lastIndex(of: ":") {
            host = String(hostAndPort[..<separator])
            let portText = String(hostAndPort[hostAndPort.index(after: separator)...])
            port = Int(portText)
            hasMalformedPort = port == nil || (port ?? 0) < 1 || (port ?? 0) > 65_535
        } else {
            host = hostAndPort
            port = nil
            hasMalformedPort = false
        }

        let reconstructedTarget: String
        if let user {
            reconstructedTarget = user + "@" + host
        } else {
            reconstructedTarget = host
        }
        let components = [user, host, reconstructedTarget].compactMap { $0 }
        hasUnsafeComponent = containsEmptyUser || components.contains { component in
            component.hasPrefix("-") || component.unicodeScalars.contains { scalar in
                CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
            }
        }
    }
}
