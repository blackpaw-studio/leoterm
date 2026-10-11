import Foundation
import os

/// B-288: whether the installed leo can attach to a dispatch subagent
/// writable. leo >= 0.47 takes `dispatch attach --rw`; an older leo (and
/// `--host` remotes older than that) only knows the read-only attach, so
/// that stays the default and the fallback.
enum LeoDispatchAccess: Equatable, Sendable {
    case readOnly
    case readWrite

    /// The extra `dispatch attach` arguments this access needs.
    var attachArguments: [String] {
        switch self {
        case .readOnly: []
        case .readWrite: ["--rw"]
        }
    }
}

extension LeoDispatchAccess {
    /// Read-write when `dispatch attach --help` lists the `--rw` flag: a
    /// help line indented under "Flags:" that starts with the flag. Prose
    /// and examples that merely mention it, and longer flags that share the
    /// prefix, don't count.
    init(fromHelp help: String) {
        let listsFlag = help.split(whereSeparator: \.isNewline).contains { line in
            guard let first = line.first, first == " " || first == "\t" else { return false }
            let flag = line.drop(while: { $0 == " " || $0 == "\t" })
            guard flag.hasPrefix("--rw") else { return false }
            return flag.dropFirst("--rw".count).first.map { $0 == " " || $0 == "\t" } ?? true
        }
        self = listsFlag ? .readWrite : .readOnly
    }
}

/// Finds out, once per leo, whether it can attach a dispatch writable by
/// reading its `dispatch attach --help` (B-288). The daemon hello carries
/// no such feature, and the same probe works over ssh for a remote leo.
/// Any doubt (no leo, a failing or timed-out probe, a host that isn't
/// configured) answers `.readOnly`, today's behavior, and isn't remembered,
/// so the next attach asks again. A definite answer is remembered: for the
/// local leo until its binary changes, for a remote until the host is edited
/// or the app restarts.
@MainActor final class LeoDispatchAccessProbe {
    static let timeout: TimeInterval = 10
    private static let logger = Logger(subsystem: "studio.blackpaw.leo.macos", category: "leo")

    private enum Key: Hashable {
        case local(path: String, modified: Date?)
        case remote(LeoHostConfiguration)
    }

    private let runner: any LeoProcessRunning
    private let executable: () throws -> String
    private let sshExecutable: String
    private let hosts: () -> [LeoHostConfiguration]
    private let modificationDate: (String) -> Date?
    private var known: [Key: LeoDispatchAccess] = [:]

    init(
        runner: any LeoProcessRunning,
        executable: @escaping () throws -> String,
        sshExecutable: String,
        hosts: @escaping () -> [LeoHostConfiguration],
        modificationDate: @escaping (String) -> Date? = { path in
            (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }
    ) {
        self.runner = runner
        self.executable = executable
        self.sshExecutable = sshExecutable
        self.hosts = hosts
        self.modificationDate = modificationDate
    }

    func access(for host: LeoHostID) async -> LeoDispatchAccess {
        do {
            let (key, command, arguments) = try probeCommand(for: host)
            if let cached = known[key] { return cached }
            let result = try await runner.run(executable: command, arguments: arguments, timeout: Self.timeout)
            guard result.status == 0 else {
                Self.logger.info("dispatch access probe for \(host.displayName, privacy: .public) exited \(result.status): read-only")
                return .readOnly
            }
            let access = LeoDispatchAccess(fromHelp: String(decoding: result.stdout, as: UTF8.self))
            Self.logger.info("dispatch access probe for \(host.displayName, privacy: .public): \(String(describing: access), privacy: .public)")
            known[key] = access
            return access
        } catch {
            Self.logger.info("dispatch access probe for \(host.displayName, privacy: .public) failed: \(error.localizedDescription, privacy: .public): read-only")
            return .readOnly
        }
    }

    private func probeCommand(for host: LeoHostID) throws -> (Key, executable: String, arguments: [String]) {
        let helpArguments = ["dispatch", "attach", "--help"]
        switch host {
        case .local:
            let path = try executable()
            return (.local(path: path, modified: modificationDate(path)), path, helpArguments)
        case .remote(let name):
            guard let configuration = hosts().first(where: { $0.name == name }) else {
                throw LeoDaemonError.hostUnavailable("Remote host \(host.displayName) is not configured")
            }
            let arguments = try LeoSSHCommand(configuration: configuration)
                .execArguments(remoteCommand: [configuration.remoteLeoPath] + helpArguments)
            return (.remote(configuration), sshExecutable, arguments)
        }
    }
}
