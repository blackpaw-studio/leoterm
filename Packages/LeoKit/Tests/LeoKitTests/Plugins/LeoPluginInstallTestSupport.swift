import Foundation

@testable import LeoKit

/// A scripted git for update and install-flow tests: `ls-remote` answers with
/// `heads[ref]`, and `checkout` writes the manifest registered for the fetched
/// sha plus a `main.js`.
final class PluginScriptGit: LeoPluginCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var heads: [String: String] = [:]
    private var manifests: [String: String] = [:]
    private var fetched: [String] = []
    private var lastFetchedSHA = ""

    func setHead(_ ref: String, sha: String) { lock.withLock { heads[ref] = sha } }
    func setManifest(sha: String, json: String) { lock.withLock { manifests[sha] = json } }
    var fetchedSHAs: [String] { lock.withLock { fetched } }

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) async throws -> LeoPluginCommandResult {
        var index = 0
        while index < arguments.count, arguments[index] == "-c" || arguments[index] == "-C" { index += 2 }
        let sub = index < arguments.count ? arguments[index] : ""
        let dir = arguments.firstIndex(of: "-C").map { URL(fileURLWithPath: arguments[$0 + 1]) }
        var out = ""
        switch sub {
        case "ls-remote":
            let ref = arguments.drop { $0 != "--" }.dropFirst(2).first ?? ""
            out = lock.withLock { heads[ref] }.map { "\($0)\trefs/heads/\(ref)\n" } ?? ""
        case "fetch":
            let sha = arguments.last ?? ""
            lock.withLock {
                fetched.append(sha)
                lastFetchedSHA = sha
            }
        case "checkout":
            if let dir {
                let sha = lock.withLock { lastFetchedSHA }
                let json = lock.withLock { manifests[sha] } ?? "{}"
                try Data(json.utf8).write(to: dir.appendingPathComponent("leo-plugin.json"))
                try Data("leo.render('x',{})".utf8).write(to: dir.appendingPathComponent("main.js"))
                try FileManager.default.createDirectory(at: dir.appendingPathComponent(".git"), withIntermediateDirectories: true)
            }
        case "rev-parse":
            out = lock.withLock { lastFetchedSHA } + "\n"
        default: break
        }
        return LeoPluginCommandResult(stdout: Data(out.utf8), stderr: Data(), status: 0)
    }
}

func pluginManifestJSON(
    id: String = "studio.blackpaw.demo", version: String = "1.0.0", network: [String] = [], secrets: Bool = false
) -> String {
    let hosts = network.map { "\"\($0)\"" }.joined(separator: ",")
    return #"{"id":"\#(id)","name":"Demo","version":"\#(version)","apiVersion":1,"main":"main.js","permissions":{"network":[\#(hosts)],"secrets":\#(secrets)}}"#
}

func makeTempRoot(_ label: String = "leo-plugin") throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}
