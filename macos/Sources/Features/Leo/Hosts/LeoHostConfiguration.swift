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

    var localSocketFileName: String {
        let slug = String(name.lowercased().unicodeScalars.map { scalar in
            switch scalar.value {
            case 48...57, 97...122, 45:
                Character(scalar)
            default:
                "_"
            }
        })
        let prefix = slug.isEmpty ? "_" : String(slug.prefix(24))
        let suffix = id.uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)-\(suffix).sock"
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
