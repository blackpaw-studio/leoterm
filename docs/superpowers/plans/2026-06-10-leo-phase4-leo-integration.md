# Leo Phase 4 — Leo Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the Leo integration layer — a sidebar + command-palette that enumerates the daemon's agents/templates, lets the user attach/spawn/stop them as grid cells, and persists/restores boards across launches.

**Architecture:** A new `macos/Sources/Features/Leo/` module owns transport (`LeoSocketClient` over the daemon's unix socket), a poll-backed `LeoAgentStore`, the `Board`/`BoardStore` persistence layer, and the `LeoSidebarView` UI. Cells reuse Ghostty's existing `SplitTree<SurfaceView>` (no new cell ownership): adding an agent = inserting a `SurfaceView` built from `CellSource.agent(name:).surfaceConfiguration`; closing = removing that leaf (detach). A `SurfaceView.ID → CellSource` registry on the controller lets boards persist and reconcile cells against the live daemon.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, `Network.framework` (`NWConnection` unix socket), Swift Testing (`import Testing`), Ghostty macOS app (`@testable import Ghostty`).

**Design doc:** `docs/superpowers/specs/2026-06-10-leo-phase4-leo-integration-design.md`

## Conventions for every task

- **Toolchain:** Xcode 26.5 is the *selected* system Xcode, but the pinned toolchain is **26.3** (memory `leo-build-toolchain`). Do NOT `xcode-select -s` (needs sudo, changes the global default). Instead set `DEVELOPER_DIR` per-command. The Xcode scheme links the prebuilt `GhosttyKit.xcframework` and has **no `zig build` phase**, so `xcodebuild test` does not hit the 26.5/Zig-linker issue — but we pin 26.3 anyway for consistency.
- **Canonical targeted test command (VERIFIED working — use this in every task):**
  ```bash
  cd /Users/evan/.leo/agents/leoterm && \
  env -i HOME="$HOME" PATH=/usr/bin:/bin:/usr/sbin:/sbin \
    DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer \
    xcodebuild test \
    -project macos/Ghostty.xcodeproj -scheme Ghostty \
    -only-testing:GhosttyTests/<SuiteName> \
    -packageAuthorizationProvider netrc \
    -destination 'platform=macOS' \
    SYMROOT="$PWD/macos/build"
  ```
  (`-packageAuthorizationProvider netrc` avoids a Sparkle SPM Keychain hang in headless sessions. Drop `-only-testing:` to run the whole `GhosttyTests` target.)
- **Build the app** (for UI/integration tasks that need a full build, no test): same env prefix + `DEVELOPER_DIR`, with `nu macos/build.nu` OR `xcodebuild build -project ... -scheme Ghostty -destination 'platform=macOS' SYMROOT=...`. The `nu macos/build.nu` wrapper uses `env -i` and will NOT forward `DEVELOPER_DIR`; prefer the explicit `xcodebuild` form above so 26.3 is used.
- **New source files** go under `macos/Sources/Features/Leo/`. **New tests** under `macos/Tests/Leo/`. The Xcode project uses **file-system-synchronized root groups** (`Sources` and `Tests` are `PBXFileSystemSynchronizedRootGroup`), so files created under those directories are **auto-included** in the `Ghostty` and `GhosttyTests` targets respectively — **no `project.pbxproj` editing and no Xcode GUI needed**. (Confirmed: Phase 2's `GridLayoutTests.swift` has zero explicit pbxproj entries.) Ignore any step below that says to add files to a target or `git add` `project.pbxproj` — those are obsolete; just create the file in the right directory.
- **Format before commit:** `swiftlint lint --strict --fix` on changed files.
- GUI feel and live-daemon behavior are verified by Evan on Dionysus (the agent session cannot see the GUI — memory `gui-verification-constraint`). Build + unit tests are the agent's gate; manual E2E is the human's.

---

### Task 0: Module scaffold + Xcode wiring + `LeoError`

**Files:**
- Create: `macos/Sources/Features/Leo/LeoError.swift`
- Create: `macos/Tests/Leo/LeoErrorTests.swift`
- Modify: `macos/Ghostty.xcodeproj/project.pbxproj` (add the new group + files to `Ghostty` and `GhosttyTests` targets)

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/LeoErrorTests.swift
import Testing
@testable import Ghostty

struct LeoErrorTests {
    @Test func descriptionsAreHumanReadable() {
        #expect(LeoError.daemonUnreachable.errorDescription == "The Leo daemon is not reachable.")
        #expect(LeoError.daemon(message: "boom").errorDescription == "Leo daemon error: boom")
        #expect(LeoError.decode(detail: "bad json").errorDescription == "Could not read the daemon response: bad json")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -project macos/Ghostty.xcodeproj -scheme Ghostty -only-testing:GhosttyTests/LeoErrorTests` (clean env per conventions).
Expected: FAIL — `LeoError` not found / files not in target.

- [ ] **Step 3: Create the error type**

```swift
// macos/Sources/Features/Leo/LeoError.swift
import Foundation

/// Errors surfaced by the Leo daemon integration layer.
enum LeoError: Error, Equatable, LocalizedError {
    /// The daemon socket could not be reached (not running, wrong path, refused).
    case daemonUnreachable
    /// The daemon returned an `{ok:false}` envelope or non-2xx status.
    case daemon(message: String)
    /// The response body could not be decoded into the expected shape.
    case decode(detail: String)

    var errorDescription: String? {
        switch self {
        case .daemonUnreachable: return "The Leo daemon is not reachable."
        case .daemon(let message): return "Leo daemon error: \(message)"
        case .decode(let detail): return "Could not read the daemon response: \(detail)"
        }
    }
}
```

- [ ] **Step 4: Wire files into the Xcode project**

Add a `Leo` group under `Sources/Features` containing `LeoError.swift` to the **Ghostty** app target, and a `Leo` group under `Tests` containing `LeoErrorTests.swift` to the **GhosttyTests** target. Easiest reliable way: open `macos/Ghostty.xcodeproj` in Xcode, drag the files into the matching groups, confirm target membership. (Manual pbxproj editing is error-prone; do it in Xcode.)

- [ ] **Step 5: Run test to verify it passes**

Run: same as Step 2.
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Leo/LeoError.swift macos/Tests/Leo/LeoErrorTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): scaffold Leo module with LeoError"
```

---

### Task 1: Domain models — `Agent`, `AgentStatus`, `Template`, `LeoEnvelope`

The daemon's `GET /agents/list` returns `{"ok":true,"data":[{name,template,repo,workspace,status,started_at,env}]}`. `leo template list --json` returns `[{name,workspace}]`.

**Files:**
- Create: `macos/Sources/Features/Leo/LeoModels.swift`
- Create: `macos/Tests/Leo/LeoModelsTests.swift`
- Add both to their Xcode targets (as Task 0 Step 4).

- [ ] **Step 1: Write the failing test (decode real-shape fixtures)**

```swift
// macos/Tests/Leo/LeoModelsTests.swift
import Testing
import Foundation
@testable import Ghostty

struct LeoModelsTests {
    @Test func decodesAgentListEnvelope() throws {
        let json = """
        {"ok":true,"data":[
          {"name":"olympus","template":"coding","repo":"blackpaw-studio/olympus",
           "workspace":"/Users/evan/.leo/agents/olympus","status":"running",
           "started_at":"2026-06-10T10:01:27.860901-04:00","env":{"X":"1"}},
          {"name":"plex","template":"coding","repo":"plex",
           "workspace":"/Users/evan/.leo/agents/plex","status":"stopped",
           "started_at":"2026-06-10T10:01:27.907514-04:00","env":{}}
        ]}
        """.data(using: .utf8)!
        let env = try LeoEnvelope<[Agent]>.decode(json)
        let agents = try env.value()
        #expect(agents.count == 2)
        #expect(agents[0].name == "olympus")
        #expect(agents[0].status == .running)
        #expect(agents[0].repo == "blackpaw-studio/olympus")
        #expect(agents[1].status == .stopped)
    }

    @Test func envelopeWithOkFalseThrowsDaemonError() {
        let json = #"{"ok":false,"error":"no such agent"}"#.data(using: .utf8)!
        #expect(throws: LeoError.daemon(message: "no such agent")) {
            _ = try LeoEnvelope<[Agent]>.decode(json).value()
        }
    }

    @Test func unknownStatusDecodesToStopped() throws {
        let json = #"{"ok":true,"data":[{"name":"a","template":"t","repo":"r","workspace":"/w","status":"weird","started_at":"2026-06-10T10:01:27Z","env":{}}]}"#.data(using: .utf8)!
        let agents = try LeoEnvelope<[Agent]>.decode(json).value()
        #expect(agents[0].status == .stopped)
    }

    @Test func decodesTemplateArray() throws {
        let json = #"[{"name":"coding","workspace":"/Users/evan/.leo/agents"},{"name":"incident","workspace":"/Users/evan/.leo/agents"}]"#.data(using: .utf8)!
        let templates = try JSONDecoder().decode([Template].self, from: json)
        #expect(templates.map(\.name) == ["coding", "incident"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/LeoModelsTests`
Expected: FAIL — `Agent`/`Template`/`LeoEnvelope` undefined.

- [ ] **Step 3: Implement the models**

```swift
// macos/Sources/Features/Leo/LeoModels.swift
import Foundation

/// Lifecycle status of an agent as reported by the daemon. Activity status
/// (working/idle/needs-you) is a Phase 5 concept derived from the cell's tmux
/// stream, not from here.
enum AgentStatus: String, Codable, Sendable, Equatable {
    case running
    case stopped

    /// Decode tolerantly: any unrecognized status is treated as stopped so a
    /// future daemon value never crashes the sidebar.
    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = AgentStatus(rawValue: raw) ?? .stopped
    }
}

/// A Leo agent as enumerated by `GET /agents/list`.
struct Agent: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let template: String
    let repo: String
    let workspace: String
    let status: AgentStatus
    let startedAt: String
    let env: [String: String]

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name, template, repo, workspace, status, env
        case startedAt = "started_at"
    }
}

/// A spawn template from `leo template list --json`.
struct Template: Codable, Sendable, Equatable, Identifiable {
    let name: String
    let workspace: String
    var id: String { name }
}

/// The daemon's response envelope: `{ "ok": bool, "error": string?, "data": T? }`.
struct LeoEnvelope<T: Decodable>: Decodable {
    let ok: Bool
    let error: String?
    let data: T?

    /// Decode an envelope from raw bytes, mapping JSON failures to `LeoError.decode`.
    static func decode(_ bytes: Data) throws(LeoError) -> LeoEnvelope<T> {
        do {
            return try JSONDecoder().decode(LeoEnvelope<T>.self, from: bytes)
        } catch {
            throw LeoError.decode(detail: String(describing: error))
        }
    }

    /// Unwrap `data`, throwing `LeoError.daemon` when `ok == false` and
    /// `LeoError.decode` when `ok == true` but `data` is missing.
    func value() throws(LeoError) -> T {
        guard ok else { throw LeoError.daemon(message: error ?? "unknown daemon error") }
        guard let data else { throw LeoError.decode(detail: "missing data field") }
        return data
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/LeoModelsTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/LeoModels.swift macos/Tests/Leo/LeoModelsTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): Agent/Template models + tolerant envelope decoding"
```

---

### Task 2: `LeoDaemon` protocol + `MockLeoDaemon` test double

**Files:**
- Create: `macos/Sources/Features/Leo/LeoDaemon.swift`
- Create: `macos/Tests/Leo/MockLeoDaemon.swift`
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/MockLeoDaemon.swift
import Foundation
@testable import Ghostty

/// In-memory `LeoDaemon` for tests. Records calls and returns scripted results.
actor MockLeoDaemon: LeoDaemon {
    var agents: [Agent]
    var templates: [Template]
    var nextError: LeoError?
    private(set) var stopped: [String] = []
    private(set) var spawned: [AgentSpawnRequest] = []
    private(set) var listCallCount = 0

    init(agents: [Agent] = [], templates: [Template] = []) {
        self.agents = agents
        self.templates = templates
    }

    func setAgents(_ agents: [Agent]) { self.agents = agents }
    func setNextError(_ error: LeoError?) { self.nextError = error }

    func listAgents() async throws(LeoError) -> [Agent] {
        listCallCount += 1
        if let nextError { self.nextError = nil; throw nextError }
        return agents
    }
    func listTemplates() async throws(LeoError) -> [Template] {
        if let nextError { self.nextError = nil; throw nextError }
        return templates
    }
    func spawn(_ request: AgentSpawnRequest) async throws(LeoError) -> Agent {
        if let nextError { self.nextError = nil; throw nextError }
        let agent = Agent(name: request.name ?? "\(request.template)-\(request.repo)",
                          template: request.template, repo: request.repo,
                          workspace: "/tmp/\(request.repo)", status: .running,
                          startedAt: "2026-06-10T00:00:00Z", env: [:])
        spawned.append(request); agents.append(agent)
        return agent
    }
    func stop(name: String) async throws(LeoError) {
        if let nextError { self.nextError = nil; throw nextError }
        stopped.append(name)
        agents = agents.map { $0.name == name ? Agent(name: $0.name, template: $0.template, repo: $0.repo, workspace: $0.workspace, status: .stopped, startedAt: $0.startedAt, env: $0.env) : $0 }
    }
    func prune(name: String) async throws(LeoError) {
        if let nextError { self.nextError = nil; throw nextError }
        agents.removeAll { $0.name == name }
    }
}
```

(The test that exercises this lives in Task 5; this step defines the double and a protocol it must conform to — which fails to compile until Step 3.)

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/LeoModelsTests` (the whole GhosttyTests target won't compile yet).
Expected: FAIL — `LeoDaemon` / `AgentSpawnRequest` undefined.

- [ ] **Step 3: Define the protocol + request type**

```swift
// macos/Sources/Features/Leo/LeoDaemon.swift
import Foundation

/// Body for `POST /agents/spawn`. `template` and `repo` are required by the daemon.
struct AgentSpawnRequest: Codable, Sendable, Equatable {
    let template: String
    let repo: String
    var name: String?
    var branch: String?
    var base: String?
}

/// The Leo daemon, abstracted for dependency injection. The production
/// implementation (`LeoSocketClient`) talks to `~/.leo/state/leo.sock`; tests
/// inject `MockLeoDaemon`.
protocol LeoDaemon: Sendable {
    func listAgents() async throws(LeoError) -> [Agent]
    func listTemplates() async throws(LeoError) -> [Template]
    func spawn(_ request: AgentSpawnRequest) async throws(LeoError) -> Agent
    func stop(name: String) async throws(LeoError) -> Void
    func prune(name: String) async throws(LeoError) -> Void
}
```

- [ ] **Step 4: Run test to verify it compiles/passes**

Run: `... -only-testing:GhosttyTests/LeoModelsTests`
Expected: PASS (target compiles; existing model tests still green).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/LeoDaemon.swift macos/Tests/Leo/MockLeoDaemon.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): LeoDaemon protocol + MockLeoDaemon test double"
```

---

### Task 3: HTTP codec — request builder + response parser (pure, TDD)

Isolate the testable HTTP/1.1 string handling from the `NWConnection` I/O. This is where we get coverage; the socket transport (Task 4) is a thin shell verified manually.

**Files:**
- Create: `macos/Sources/Features/Leo/LeoHTTP.swift`
- Create: `macos/Tests/Leo/LeoHTTPTests.swift`
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/LeoHTTPTests.swift
import Testing
import Foundation
@testable import Ghostty

struct LeoHTTPTests {
    @Test func buildsGetRequestBytes() {
        let req = LeoHTTPRequest(method: "GET", path: "/agents/list")
        let text = String(data: req.serialized(), encoding: .utf8)!
        #expect(text.hasPrefix("GET /agents/list HTTP/1.1\r\n"))
        #expect(text.contains("Host: localhost\r\n"))
        #expect(text.contains("Connection: close\r\n"))
        #expect(text.hasSuffix("\r\n\r\n"))
    }

    @Test func buildsPostRequestWithJSONBody() {
        let body = #"{"template":"coding","repo":"a/b"}"#.data(using: .utf8)!
        let req = LeoHTTPRequest(method: "POST", path: "/agents/spawn", body: body)
        let text = String(data: req.serialized(), encoding: .utf8)!
        #expect(text.contains("POST /agents/spawn HTTP/1.1\r\n"))
        #expect(text.contains("Content-Type: application/json\r\n"))
        #expect(text.contains("Content-Length: \(body.count)\r\n"))
        #expect(text.hasSuffix(#"{"template":"coding","repo":"a/b"}"#))
    }

    @Test func parsesResponseStatusAndBody() throws {
        let raw = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 13\r\n\r\n{\"ok\":true}\r\n".data(using: .utf8)!
        let resp = try LeoHTTPResponse.parse(raw)
        #expect(resp.status == 200)
        #expect(String(data: resp.body, encoding: .utf8) == "{\"ok\":true}\r\n")
    }

    @Test func parseRejectsMalformedResponse() {
        let raw = "not http".data(using: .utf8)!
        #expect(throws: LeoError.self) { _ = try LeoHTTPResponse.parse(raw) }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/LeoHTTPTests`
Expected: FAIL — `LeoHTTPRequest`/`LeoHTTPResponse` undefined.

- [ ] **Step 3: Implement the codec**

```swift
// macos/Sources/Features/Leo/LeoHTTP.swift
import Foundation

/// A minimal HTTP/1.1 request to the daemon socket. We always close the
/// connection per-request (`Connection: close`) so the response terminates at EOF.
struct LeoHTTPRequest {
    let method: String
    let path: String
    var body: Data?

    func serialized() -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\n"
        head += "Host: localhost\r\n"
        head += "Connection: close\r\n"
        if let body {
            head += "Content-Type: application/json\r\n"
            head += "Content-Length: \(body.count)\r\n"
        }
        head += "\r\n"
        var data = Data(head.utf8)
        if let body { data.append(body) }
        return data
    }
}

/// A parsed HTTP/1.1 response. Only the status line and body are needed.
struct LeoHTTPResponse {
    let status: Int
    let body: Data

    /// Parse raw response bytes. Throws `LeoError.decode` on a malformed head.
    static func parse(_ raw: Data) throws(LeoError) -> LeoHTTPResponse {
        // Split head/body on the first CRLFCRLF.
        let sep = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: sep) else {
            throw LeoError.decode(detail: "no header terminator in response")
        }
        let head = raw[raw.startIndex..<range.lowerBound]
        let body = raw[range.upperBound...]
        guard let headText = String(data: head, encoding: .utf8),
              let statusLine = headText.split(separator: "\r\n").first else {
            throw LeoError.decode(detail: "unreadable response head")
        }
        // "HTTP/1.1 200 OK"
        let parts = statusLine.split(separator: " ")
        guard parts.count >= 2, parts[0].hasPrefix("HTTP/"), let code = Int(parts[1]) else {
            throw LeoError.decode(detail: "bad status line: \(statusLine)")
        }
        return LeoHTTPResponse(status: code, body: Data(body))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/LeoHTTPTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/LeoHTTP.swift macos/Tests/Leo/LeoHTTPTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): pure HTTP/1.1 request builder + response parser"
```

---

### Task 4: `LeoSocketClient` transport (NWConnection unix socket) + template CLI

This is the I/O glue: connect to the unix socket, send `LeoHTTPRequest.serialized()`, read to EOF, parse with `LeoHTTPResponse`, decode the envelope. No unit test (real socket I/O) — verified by build + manual run against the live daemon. `listTemplates()` shells out to `leo template list --json`.

**Files:**
- Create: `macos/Sources/Features/Leo/LeoSocketClient.swift`
- Add to Xcode target.

- [ ] **Step 1: Implement the socket transport**

```swift
// macos/Sources/Features/Leo/LeoSocketClient.swift
import Foundation
import Network
import os

/// Production `LeoDaemon`: HTTP/1.1 over the daemon's unix socket
/// (`~/.leo/state/leo.sock`). The socket's `0600` file permissions are the
/// auth — no token is sent. Templates are not exposed on the socket, so
/// `listTemplates()` shells out to the `leo` CLI.
struct LeoSocketClient: LeoDaemon {
    let socketPath: String
    let leoExecutable: String
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-daemon")

    init(socketPath: String = NSString(string: "~/.leo/state/leo.sock").expandingTildeInPath,
         leoExecutable: String = NSString(string: "~/.local/bin/leo").expandingTildeInPath) {
        self.socketPath = socketPath
        self.leoExecutable = leoExecutable
    }

    // MARK: LeoDaemon

    func listAgents() async throws(LeoError) -> [Agent] {
        let body = try await request(.init(method: "GET", path: "/agents/list"))
        return try LeoEnvelope<[Agent]>.decode(body).value()
    }

    func spawn(_ req: AgentSpawnRequest) async throws(LeoError) -> Agent {
        let payload: Data
        do { payload = try JSONEncoder().encode(req) }
        catch { throw LeoError.decode(detail: "encode spawn: \(error)") }
        let body = try await request(.init(method: "POST", path: "/agents/spawn", body: payload))
        return try LeoEnvelope<Agent>.decode(body).value()
    }

    func stop(name: String) async throws(LeoError) {
        let body = try await request(.init(method: "POST", path: "/agents/\(escape(name))/stop"))
        _ = try LeoEnvelope<EmptyData>.decode(body).value()
    }

    func prune(name: String) async throws(LeoError) {
        let body = try await request(.init(method: "POST", path: "/agents/\(escape(name))/prune"))
        _ = try LeoEnvelope<EmptyData>.decode(body).value()
    }

    func listTemplates() async throws(LeoError) -> [Template] {
        let out = try runCLI(["template", "list", "--json"])
        do { return try JSONDecoder().decode([Template].self, from: out) }
        catch { throw LeoError.decode(detail: "template list: \(error)") }
    }

    // MARK: - Transport

    /// `{}` placeholder for endpoints whose `data` we ignore.
    private struct EmptyData: Decodable {}

    private func escape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }

    /// Send one request over a fresh connection and return the response body.
    private func request(_ req: LeoHTTPRequest) async throws(LeoError) -> Data {
        do {
            return try await withCheckedThrowingContinuation { continuation in
                let endpoint = NWEndpoint.unix(path: socketPath)
                let conn = NWConnection(to: endpoint, using: .tcp)
                var received = Data()
                let queue = DispatchQueue(label: "leo-socket")

                func finish(_ result: Result<Data, LeoError>) {
                    conn.cancel()
                    switch result {
                    case .success(let d): continuation.resume(returning: d)
                    case .failure(let e): continuation.resume(throwing: e)
                    }
                }

                func readLoop() {
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                        if let data { received.append(data) }
                        if let error {
                            finish(.failure(.daemonUnreachable))
                            return
                        }
                        if isComplete {
                            do {
                                let resp = try LeoHTTPResponse.parse(received)
                                guard (200..<300).contains(resp.status) else {
                                    // Try to surface the daemon's JSON error message.
                                    let msg = (try? LeoEnvelope<EmptyData>.decode(resp.body))?.error
                                        ?? "HTTP \(resp.status)"
                                    finish(.failure(.daemon(message: msg)))
                                    return
                                }
                                finish(.success(resp.body))
                            } catch let e as LeoError {
                                finish(.failure(e))
                            } catch {
                                finish(.failure(.decode(detail: String(describing: error))))
                            }
                        } else {
                            readLoop()
                        }
                    }
                }

                conn.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        conn.send(content: req.serialized(), completion: .contentProcessed { sendErr in
                            if sendErr != nil { finish(.failure(.daemonUnreachable)); return }
                            readLoop()
                        })
                    case .failed, .cancelled:
                        finish(.failure(.daemonUnreachable))
                    default:
                        break
                    }
                }
                conn.start(queue: queue)
            }
        } catch let e as LeoError {
            throw e
        } catch {
            throw LeoError.daemonUnreachable
        }
    }

    /// Run the `leo` CLI and return stdout. Used only for templates.
    private func runCLI(_ args: [String]) throws(LeoError) -> Data {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: leoExecutable)
        proc.arguments = args
        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        do {
            try proc.run()
        } catch {
            throw LeoError.daemonUnreachable
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            throw LeoError.daemon(message: "leo \(args.joined(separator: " ")) exited \(proc.terminationStatus)")
        }
        return data
    }
}
```

- [ ] **Step 2: Build**

Run: `nu macos/build.nu`
Expected: builds clean (warnings ok). No unit test — this is I/O glue.

- [ ] **Step 3: Manual smoke test against the live daemon (Evan, on Dionysus)**

Add a temporary scratch call (e.g. in a debug menu or an `#if DEBUG` `applicationDidFinishLaunching` log) that calls `try await LeoSocketClient().listAgents()` and logs the count, OR verify indirectly once Task 6's store is wired. Document the result. (This step can be deferred to the Task 6/12 manual pass to avoid throwaway code — note it here so it isn't forgotten.)

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Leo/LeoSocketClient.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): LeoSocketClient over unix socket + template CLI shell-out"
```

---

### Task 5: `LeoAgentStore` — poll/refresh state machine

`@MainActor @Observable` view-model the sidebar binds to. Holds agents/templates + a connection state; refreshes on demand and (Task 12) on a timer while visible.

**Files:**
- Create: `macos/Sources/Features/Leo/LeoAgentStore.swift`
- Create: `macos/Tests/Leo/LeoAgentStoreTests.swift`
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/LeoAgentStoreTests.swift
import Testing
import Foundation
@testable import Ghostty

@MainActor
struct LeoAgentStoreTests {
    @Test func refreshPopulatesAgentsAndMarksOnline() async {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        #expect(store.agents.count == 1)
        #expect(store.connection == .online)
    }

    @Test func refreshFailureMarksOffline() async {
        let daemon = MockLeoDaemon()
        await daemon.setNextError(.daemonUnreachable)
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        #expect(store.connection == .offline)
        #expect(store.agents.isEmpty)
    }

    @Test func stopRefreshesAndReflectsNewStatus() async {
        let daemon = MockLeoDaemon(agents: [
            Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .running, startedAt: "t", env: [:])
        ])
        let store = LeoAgentStore(daemon: daemon)
        await store.refresh()
        await store.stop(name: "a")
        #expect(store.agents.first?.status == .stopped)
        #expect(await daemon.stopped == ["a"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/LeoAgentStoreTests`
Expected: FAIL — `LeoAgentStore` undefined.

- [ ] **Step 3: Implement the store**

```swift
// macos/Sources/Features/Leo/LeoAgentStore.swift
import Foundation
import Observation
import os

/// Observable view-model over the Leo daemon. The sidebar binds to it.
/// Polling is driven externally (Task 12 starts/stops a timer based on sidebar
/// visibility); this type exposes `refresh()` plus the lifecycle actions.
@MainActor
@Observable
final class LeoAgentStore {
    enum Connection: Equatable { case unknown, online, offline }

    private(set) var agents: [Agent] = []
    private(set) var templates: [Template] = []
    private(set) var connection: Connection = .unknown
    private(set) var lastError: String?

    private let daemon: any LeoDaemon
    private static let logger = Logger(subsystem: "com.mitchellh.ghostty", category: "leo-store")

    init(daemon: any LeoDaemon = LeoSocketClient()) {
        self.daemon = daemon
    }

    /// Re-fetch the agent roster. Never throws — failures flip `connection` to
    /// `.offline` so the UI degrades cleanly instead of erroring.
    func refresh() async {
        do {
            let fetched = try await daemon.listAgents()
            agents = fetched
            connection = .online
            lastError = nil
        } catch {
            connection = .offline
            lastError = error.errorDescription
            Self.logger.warning("agent refresh failed: \(error.errorDescription ?? "?", privacy: .public)")
        }
    }

    /// Fetch templates for the spawn sheet (best-effort).
    func refreshTemplates() async {
        if let fetched = try? await daemon.listTemplates() { templates = fetched }
    }

    /// Spawn an agent then refresh. Returns the new agent on success.
    @discardableResult
    func spawn(_ request: AgentSpawnRequest) async -> Agent? {
        do {
            let agent = try await daemon.spawn(request)
            await refresh()
            return agent
        } catch {
            lastError = error.errorDescription
            return nil
        }
    }

    /// Stop an agent then refresh.
    func stop(name: String) async {
        do { try await daemon.stop(name: name) } catch { lastError = error.errorDescription }
        await refresh()
    }

    func prune(name: String) async {
        do { try await daemon.prune(name: name) } catch { lastError = error.errorDescription }
        await refresh()
    }

    /// True if a running agent with this name exists in the current roster.
    func isRunning(_ name: String) -> Bool {
        agents.contains { $0.name == name && $0.status == .running }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/LeoAgentStoreTests`
Expected: PASS (all 3 tests).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/LeoAgentStore.swift macos/Tests/Leo/LeoAgentStoreTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): LeoAgentStore observable poll/refresh + lifecycle actions"
```

---

### Task 6: `CellSource` Codable + equality round-trip

`Board` persistence needs `CellSource` to encode/decode. Extend the existing enum.

**Files:**
- Modify: `macos/Sources/Features/Grid/CellSource.swift`
- Create: `macos/Tests/Cell/CellSourceCodableTests.swift` (alongside existing `CellSourceTests.swift`)
- Add the test to the Xcode target.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Cell/CellSourceCodableTests.swift
import Testing
import Foundation
@testable import Ghostty

struct CellSourceCodableTests {
    @Test func ptyRoundTrips() throws {
        let data = try JSONEncoder().encode(CellSource.pty)
        #expect(try JSONDecoder().decode(CellSource.self, from: data) == .pty)
    }

    @Test func agentRoundTrips() throws {
        let source = CellSource.agent(name: "olympus")
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(CellSource.self, from: data) == source)
    }

    @Test func agentEncodesStableShape() throws {
        let data = try JSONEncoder().encode(CellSource.agent(name: "olympus"))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"agent\""))
        #expect(json.contains("\"olympus\""))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/CellSourceCodableTests`
Expected: FAIL — `CellSource` is not `Codable`.

- [ ] **Step 3: Add Codable conformance**

Add to `macos/Sources/Features/Grid/CellSource.swift` (the enum currently declares `enum CellSource: Equatable`). Change the declaration to `enum CellSource: Equatable, Codable` and add an explicit, stable coding strategy so the persisted shape doesn't depend on Swift's synthesized enum format:

```swift
extension CellSource {
    private enum CodingKeys: String, CodingKey { case kind, name }
    private enum Kind: String, Codable { case pty, agent }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pty:
            try c.encode(Kind.pty, forKey: .kind)
        case .agent(let name):
            try c.encode(Kind.agent, forKey: .kind)
            try c.encode(name, forKey: .name)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .pty: self = .pty
        case .agent: self = .agent(name: try c.decode(String.self, forKey: .name))
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/CellSourceCodableTests`
Expected: PASS. Also re-run `... -only-testing:GhosttyTests/CellSourceTests` to confirm no regression.

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Grid/CellSource.swift macos/Tests/Cell/CellSourceCodableTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(grid): make CellSource Codable with a stable shape"
```

---

### Task 7: Controller cell registry + `addCell`/`closeCell`

Give `BaseTerminalController` a `SurfaceView.ID → CellSource` registry and two helpers that wrap the existing `newSplit`/`removing` primitives. Default new surfaces are `.pty`; agent cells record `.agent(name:)`.

**Files:**
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift` (add registry + methods near `newSplit` ~line 236 and the removal path ~line 781)
- Create: `macos/Tests/Leo/CellRegistryTests.swift` (tests the pure registry helper extracted below)
- Create: `macos/Sources/Features/Leo/CellRegistry.swift`
- Add to Xcode targets.

Rationale for a standalone `CellRegistry`: `BaseTerminalController` is an AppKit singleton that's hard to unit-test, so the mapping logic lives in a small testable value type the controller holds.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/CellRegistryTests.swift
import Testing
import Foundation
@testable import Ghostty

struct CellRegistryTests {
    @Test func recordsAndLooksUpSource() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "olympus"))
        #expect(reg.source(for: id) == .agent(name: "olympus"))
    }

    @Test func defaultsToPTYWhenUnknown() {
        let reg = CellRegistry()
        #expect(reg.source(for: UUID()) == .pty)
    }

    @Test func forgetRemovesEntry() {
        var reg = CellRegistry()
        let id = UUID()
        reg.record(id: id, source: .agent(name: "a"))
        reg.forget(id: id)
        #expect(reg.source(for: id) == .pty)
    }

    @Test func agentNamesListsOnlyAgents() {
        var reg = CellRegistry()
        let a = UUID(); let b = UUID()
        reg.record(id: a, source: .agent(name: "a"))
        reg.record(id: b, source: .pty)
        #expect(reg.agentNames.sorted() == ["a"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/CellRegistryTests`
Expected: FAIL — `CellRegistry` undefined.

- [ ] **Step 3: Implement `CellRegistry`**

```swift
// macos/Sources/Features/Leo/CellRegistry.swift
import Foundation

/// Maps a surface's stable ID to the `CellSource` that backs it, so boards can
/// be persisted/restored and the sidebar can answer "is this agent on the board?".
/// Unknown IDs resolve to `.pty` (a plain shell), matching how surfaces created
/// outside the Leo flow behave.
struct CellRegistry {
    private var sources: [UUID: CellSource] = [:]

    func source(for id: UUID) -> CellSource { sources[id] ?? .pty }
    mutating func record(id: UUID, source: CellSource) { sources[id] = source }
    mutating func forget(id: UUID) { sources.removeValue(forKey: id) }

    /// Names of agents currently backing a cell.
    var agentNames: [String] {
        sources.values.compactMap { if case .agent(let n) = $0 { return n } else { return nil } }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/CellRegistryTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Wire the registry + helpers into `BaseTerminalController`**

In `macos/Sources/Features/Terminal/BaseTerminalController.swift`, add a stored property near the other state:

```swift
/// Maps surface IDs to their Leo cell source (agent vs plain shell).
var cellRegistry = CellRegistry()
```

Add these methods (place after `newSplit`, ~line 270):

```swift
/// Add a new cell backed by the given Leo source. Inserts relative to the
/// focused surface (or the tree's first leaf). The grid auto-packs, so the
/// split direction is cosmetic; `.right` keeps the math simple.
@discardableResult
func addCell(source: CellSource) -> Ghostty.SurfaceView? {
    let anchor = focusedSurface ?? Array(surfaceTree).first
    guard let anchor else { return nil }
    guard let view = newSplit(at: anchor, direction: .right,
                              baseConfig: source.surfaceConfiguration) else { return nil }
    cellRegistry.record(id: view.uuid, source: source)
    return view
}

/// Close (detach) a cell: remove its leaf and forget its source. The agent,
/// if any, keeps running in the daemon (lifecycle model A).
func closeCell(_ view: Ghostty.SurfaceView) {
    guard let node = surfaceTree.root?.node(view: view) else { return }
    cellRegistry.forget(id: view.uuid)
    let newTree = surfaceTree.removing(node)
    replaceSurfaceTree(newTree, moveFocusFrom: focusedSurface, undoAction: "Close Cell")
}
```

Note: confirm the SurfaceView's stable id accessor. `GridLayout`/`PlacedCell` key on `Ghostty.SurfaceView.ID`. Use whatever that resolves to (`view.uuid` if present, else `view.id`); match the type `CellRegistry` keys on (adjust `UUID` to `Ghostty.SurfaceView.ID` if they differ). Verify against `SurfaceView`'s `Identifiable` conformance before writing — keep the registry key type identical to the layout's.

- [ ] **Step 6: Build**

Run: `nu macos/build.nu`
Expected: builds clean.

- [ ] **Step 7: Commit**

```bash
git add macos/Sources/Features/Leo/CellRegistry.swift macos/Tests/Leo/CellRegistryTests.swift macos/Sources/Features/Terminal/BaseTerminalController.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): cell registry + addCell/closeCell on the controller"
```

---

### Task 8: `Board`/`BoardCell` models + reconciliation (pure, TDD)

**Files:**
- Create: `macos/Sources/Features/Leo/Board.swift`
- Create: `macos/Tests/Leo/BoardTests.swift`
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/BoardTests.swift
import Testing
import Foundation
@testable import Ghostty

struct BoardTests {
    private func agentCell(_ name: String) -> BoardCell {
        BoardCell(source: .agent(name: name), lastKnownAgent: .init(name: name, repo: "x/\(name)"))
    }

    @Test func boardRoundTripsThroughCodable() throws {
        let board = Board(name: "work", cells: [agentCell("a"), BoardCell(source: .pty)])
        let data = try JSONEncoder().encode(board)
        let decoded = try JSONDecoder().decode(Board.self, from: data)
        #expect(decoded == board)
    }

    @Test func reconcileMarksMissingAgentsDead() {
        let board = Board(name: "work", cells: [agentCell("alive"), agentCell("gone"), BoardCell(source: .pty)])
        let live = [Agent(name: "alive", template: "coding", repo: "x/alive", workspace: "/w", status: .running, startedAt: "t", env: [:])]
        let result = board.reconciled(against: live)
        #expect(result.cells[0].liveness == .attached)   // alive agent
        #expect(result.cells[1].liveness == .dead)        // gone agent
        #expect(result.cells[2].liveness == .attached)    // pty always attached
    }

    @Test func reconcileMarksStoppedAgentDead() {
        let board = Board(name: "w", cells: [agentCell("a")])
        let live = [Agent(name: "a", template: "coding", repo: "x/a", workspace: "/w", status: .stopped, startedAt: "t", env: [:])]
        #expect(board.reconciled(against: live).cells[0].liveness == .dead)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/BoardTests`
Expected: FAIL — `Board`/`BoardCell` undefined.

- [ ] **Step 3: Implement the models + reconciliation**

```swift
// macos/Sources/Features/Leo/Board.swift
import Foundation

/// A snapshot of the agent a cell was attached to, kept so a dead cell can be
/// labeled and offered for respawn even when the agent is gone from the daemon.
struct AgentSnapshot: Codable, Equatable, Sendable {
    let name: String
    let repo: String
}

/// Whether a board cell is currently backed by a live source.
enum CellLiveness: Equatable, Sendable { case attached, dead }

/// One cell on a board. `liveness` is transient (recomputed on restore), not persisted.
struct BoardCell: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let source: CellSource
    var lastKnownAgent: AgentSnapshot?
    var liveness: CellLiveness

    init(id: UUID = UUID(), source: CellSource, lastKnownAgent: AgentSnapshot? = nil, liveness: CellLiveness = .attached) {
        self.id = id
        self.source = source
        self.lastKnownAgent = lastKnownAgent
        self.liveness = liveness
    }

    enum CodingKeys: String, CodingKey { case id, source, lastKnownAgent }
    // liveness is intentionally not encoded; it is derived on reconcile.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        source = try c.decode(CellSource.self, forKey: .source)
        lastKnownAgent = try c.decodeIfPresent(AgentSnapshot.self, forKey: .lastKnownAgent)
        liveness = .attached
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(lastKnownAgent, forKey: .lastKnownAgent)
    }
}

/// A curated set of agents/cells, mapped to a Ghostty tab.
struct Board: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    var cells: [BoardCell]

    init(id: UUID = UUID(), name: String, cells: [BoardCell]) {
        self.id = id
        self.name = name
        self.cells = cells
    }

    /// Recompute each cell's liveness against the live daemon roster: an agent
    /// cell is `.dead` if no running agent with its name exists; pty cells are
    /// always `.attached`.
    func reconciled(against liveAgents: [Agent]) -> Board {
        let running = Set(liveAgents.filter { $0.status == .running }.map(\.name))
        let newCells = cells.map { cell -> BoardCell in
            var c = cell
            switch cell.source {
            case .pty:
                c.liveness = .attached
            case .agent(let name):
                c.liveness = running.contains(name) ? .attached : .dead
            }
            return c
        }
        return Board(id: id, name: name, cells: newCells)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/BoardTests`
Expected: PASS (all 4 tests).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/Board.swift macos/Tests/Leo/BoardTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): Board/BoardCell models + dead-cell reconciliation"
```

---

### Task 9: `BoardStore` — persist/load `boards.json`

**Files:**
- Create: `macos/Sources/Features/Leo/BoardStore.swift`
- Create: `macos/Tests/Leo/BoardStoreTests.swift`
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test**

```swift
// macos/Tests/Leo/BoardStoreTests.swift
import Testing
import Foundation
@testable import Ghostty

struct BoardStoreTests {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("boards-\(UUID()).json")
    }

    @Test func savesAndLoadsRoundTrip() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = BoardStore(fileURL: url)
        let boards = [Board(name: "work", cells: [BoardCell(source: .agent(name: "a"))])]
        try store.save(boards)
        #expect(try store.load() == boards)
    }

    @Test func loadReturnsEmptyWhenFileMissing() throws {
        let store = BoardStore(fileURL: tempURL())
        #expect(try store.load().isEmpty)
    }

    @Test func loadThrowsOnCorruptFile() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { _ = try BoardStore(fileURL: url).load() }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/BoardStoreTests`
Expected: FAIL — `BoardStore` undefined.

- [ ] **Step 3: Implement `BoardStore`**

```swift
// macos/Sources/Features/Leo/BoardStore.swift
import Foundation

/// Persists boards (view state only) to JSON. Default location:
/// `~/Library/Application Support/Leo/boards.json`.
struct BoardStore {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.fileURL = base.appendingPathComponent("Leo/boards.json")
        }
    }

    /// Load saved boards. Returns `[]` when the file does not exist yet.
    /// Throws on a corrupt/unreadable file (caller decides whether to reset).
    func load() throws -> [Board] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Board].self, from: data)
    }

    /// Write boards atomically, creating the parent directory if needed.
    func save(_ boards: [Board]) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(boards).write(to: fileURL, options: .atomic)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/BoardStoreTests`
Expected: PASS (all 3 tests).

- [ ] **Step 5: Commit**

```bash
git add macos/Sources/Features/Leo/BoardStore.swift macos/Tests/Leo/BoardStoreTests.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): BoardStore JSON persistence with atomic writes"
```

---

### Task 10: `DeadCellView` — placeholder for a missing agent

A SwiftUI view shown in place of a surface when a restored agent is gone. Build-verified (UI).

**Files:**
- Create: `macos/Sources/Features/Leo/DeadCellView.swift`
- Add to Xcode target.

- [ ] **Step 1: Implement the view**

```swift
// macos/Sources/Features/Leo/DeadCellView.swift
import SwiftUI

/// Placeholder rendered in a board slot whose agent is no longer running.
/// Keeps the slot/size and offers respawn or removal.
struct DeadCellView: View {
    let snapshot: AgentSnapshot
    let onRespawn: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)
            Text(snapshot.name)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(snapshot.repo)
                .font(.caption)
                .foregroundStyle(.tertiary)
            Text("Agent stopped")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 8) {
                Button("Respawn", action: onRespawn)
                Button("Remove", role: .destructive, action: onRemove)
            }
            .controlSize(.small)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }
}
```

- [ ] **Step 2: Build**

Run: `nu macos/build.nu`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add macos/Sources/Features/Leo/DeadCellView.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): DeadCellView placeholder for stopped agents"
```

---

### Task 11: `LeoSidebarView` + toggle + wiring

The sidebar binds to a shared `LeoAgentStore`, lists running agents + templates, and routes clicks to the focused window's controller (`addCell`/`closeCell`/`store.stop`). Build-verified + manual.

**Files:**
- Create: `macos/Sources/Features/Leo/LeoSidebarView.swift`
- Create: `macos/Sources/Features/Leo/LeoSidebarController.swift` (NSHostingController + show/hide; owns the timer)
- Modify: `macos/Sources/Features/Terminal/TerminalView.swift` (host the sidebar beside `TerminalGridView` via an `HStack`)
- Modify: `macos/Sources/App/macOS/AppDelegate.swift` (own the shared `LeoAgentStore`; add a "Toggle Leo Sidebar" menu item + keybind)

- [ ] **Step 1: Implement the sidebar view**

```swift
// macos/Sources/Features/Leo/LeoSidebarView.swift
import SwiftUI

/// Side panel listing the daemon's agents + templates. Actions are delivered
/// via closures so the view stays decoupled from the controller/AppKit layer.
struct LeoSidebarView: View {
    @Bindable var store: LeoAgentStore
    /// Names of agents already on the current board (drawn with a checkmark).
    let onBoard: Set<String>
    let onAttach: (Agent) -> Void
    let onStop: (Agent) -> Void
    let onNewAgent: () -> Void
    let onNewTerminal: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            List {
                Section("Agents") {
                    if store.agents.isEmpty {
                        Text(store.connection == .offline ? "Daemon offline" : "No agents")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    ForEach(store.agents) { agent in
                        agentRow(agent)
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            footer
        }
        .frame(width: 240)
        .task { await store.refresh() }
    }

    private var header: some View {
        HStack {
            Text("Leo").font(.headline)
            Spacer()
            Circle()
                .fill(store.connection == .online ? Color.green : Color.secondary)
                .frame(width: 8, height: 8)
            Button { Task { await store.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
        }
        .padding(8)
    }

    private func agentRow(_ agent: Agent) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(agent.status == .running ? Color.green : Color.secondary)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.name).font(.callout).lineLimit(1)
                Text(agent.repo).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if onBoard.contains(agent.name) {
                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onAttach(agent) }
        .contextMenu {
            Button("Attach to board") { onAttach(agent) }
            if agent.status == .running {
                Button("Stop agent", role: .destructive) { onStop(agent) }
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Button { onNewAgent() } label: { Label("New Agent", systemImage: "plus.circle").frame(maxWidth: .infinity) }
            Button { onNewTerminal() } label: { Label("New Terminal", systemImage: "terminal").frame(maxWidth: .infinity) }
        }
        .buttonStyle(.bordered)
        .padding(8)
    }
}
```

- [ ] **Step 2: Implement the sidebar controller (visibility + polling timer)**

```swift
// macos/Sources/Features/Leo/LeoSidebarController.swift
import AppKit
import SwiftUI

/// Owns the poll timer for the shared store while the sidebar is visible.
/// Visibility itself is rendered inline in TerminalView (Step 3); this object
/// is the timer + shared-store holder injected via the environment/AppDelegate.
@MainActor
final class LeoSidebarModel: ObservableObject {
    @Published var isVisible: Bool = false
    let store: LeoAgentStore
    private var pollTask: Task<Void, Never>?

    init(store: LeoAgentStore) { self.store = store }

    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        visible ? startPolling() : stopPolling()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.store.refresh()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
```

- [ ] **Step 3: Host the sidebar in `TerminalView`**

In `macos/Sources/Features/Terminal/TerminalView.swift`, wrap the existing `TerminalGridView` in an `HStack` with the sidebar when visible. Inject `LeoSidebarModel` (from the AppDelegate-owned shared instance) via `@EnvironmentObject` or an explicit property on the view model. Replace the `TerminalGridView(...)` block (~line 82) with:

```swift
HStack(spacing: 0) {
    if leoSidebar.isVisible {
        LeoSidebarView(
            store: leoSidebar.store,
            onBoard: Set(delegate?.cellRegistry.agentNames ?? []),
            onAttach: { agent in self.delegate?.addCell(source: .agent(name: agent.name)) },
            onStop: { agent in Task { await leoSidebar.store.stop(name: agent.name) } },
            onNewAgent: { self.delegate?.presentSpawnSheet() },
            onNewTerminal: { self.delegate?.addCell(source: .pty) })
        Divider()
    }
    TerminalGridView(
        tree: viewModel.surfaceTree,
        action: { delegate?.performSplitAction($0) })
        // ...existing modifiers unchanged...
}
```

`delegate` must expose `cellRegistry`, `addCell(source:)`, and `presentSpawnSheet()` — `addCell`/`cellRegistry` exist from Task 7; add `presentSpawnSheet()` in Task 12. Confirm the delegate protocol (`performSplitAction` is declared at `TerminalView.swift:22`) and add the new requirements there.

- [ ] **Step 4: Own the shared store + add the toggle in `AppDelegate`**

In `macos/Sources/App/macOS/AppDelegate.swift`, add:

```swift
/// Shared Leo daemon store + sidebar model, one per app.
let leoSidebar = LeoSidebarModel(store: LeoAgentStore())
```

Add a menu item (under a "Leo" or "View" menu) wired to:

```swift
@IBAction func toggleLeoSidebar(_ sender: Any?) {
    leoSidebar.setVisible(!leoSidebar.isVisible)
}
```

Pass `leoSidebar` into the SwiftUI environment where `TerminalView` is created so Step 3's `leoSidebar` resolves. (Follow the existing pattern used for `ghostty`/`@EnvironmentObject` injection in this file.)

- [ ] **Step 5: Build**

Run: `nu macos/build.nu`
Expected: builds clean.

- [ ] **Step 6: Commit**

```bash
git add macos/Sources/Features/Leo/LeoSidebarView.swift macos/Sources/Features/Leo/LeoSidebarController.swift macos/Sources/Features/Terminal/TerminalView.swift macos/Sources/App/macOS/AppDelegate.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): sidebar view + toggle + polling while visible"
```

---

### Task 12: Spawn sheet

A sheet to pick template + repo (+ optional branch), call `store.spawn`, and land the result on the board. Build-verified + manual.

**Files:**
- Create: `macos/Sources/Features/Leo/SpawnAgentSheet.swift`
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift` (add `presentSpawnSheet()` presenting an `NSHostingController`)

- [ ] **Step 1: Implement the sheet view**

```swift
// macos/Sources/Features/Leo/SpawnAgentSheet.swift
import SwiftUI

/// Collects spawn parameters and reports the chosen request. The caller runs
/// the spawn (so this view stays free of async/daemon concerns) and adds the
/// resulting cell to the board.
struct SpawnAgentSheet: View {
    @Bindable var store: LeoAgentStore
    let onSpawn: (AgentSpawnRequest) -> Void
    let onCancel: () -> Void

    @State private var template: String = ""
    @State private var repo: String = ""
    @State private var branch: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Agent").font(.headline)
            Picker("Template", selection: $template) {
                ForEach(store.templates) { t in Text(t.name).tag(t.name) }
            }
            TextField("Repo (owner/name or workspace name)", text: $repo)
            TextField("Branch (optional, requires owner/repo)", text: $branch)
            if let err = store.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                Button("Spawn") {
                    onSpawn(AgentSpawnRequest(
                        template: template, repo: repo,
                        name: nil,
                        branch: branch.isEmpty ? nil : branch,
                        base: nil))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(template.isEmpty || repo.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .task {
            await store.refreshTemplates()
            if template.isEmpty { template = store.templates.first?.name ?? "" }
        }
    }
}
```

- [ ] **Step 2: Present it from the controller**

Add `presentSpawnSheet()` to `BaseTerminalController` (and declare it on the `TerminalView` delegate protocol used in Task 11):

```swift
func presentSpawnSheet() {
    guard let window else { return }
    let store = (NSApp.delegate as? AppDelegate)?.leoSidebar.store ?? LeoAgentStore()
    var hosting: NSHostingController<SpawnAgentSheet>!
    let view = SpawnAgentSheet(
        store: store,
        onSpawn: { [weak self] request in
            self?.dismiss(hosting)
            Task {
                if let agent = await store.spawn(request) {
                    self?.addCell(source: .agent(name: agent.name))
                }
            }
        },
        onCancel: { [weak self] in self?.dismiss(hosting) })
    hosting = NSHostingController(rootView: view)
    window.contentViewController?.presentAsSheet(hosting)
}

private func dismiss(_ vc: NSViewController?) {
    guard let vc else { return }
    window?.contentViewController?.dismiss(vc)
}
```

Match the actual sheet-presentation idiom this codebase already uses (search for `presentAsSheet`/`beginSheet`); adapt if a different pattern is established.

- [ ] **Step 3: Build**

Run: `nu macos/build.nu`
Expected: builds clean.

- [ ] **Step 4: Commit**

```bash
git add macos/Sources/Features/Leo/SpawnAgentSheet.swift macos/Sources/Features/Terminal/BaseTerminalController.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): spawn-agent sheet (template + repo picker)"
```

---

### Task 13: Command-palette entries

Register Leo actions in the existing palette so keyboard users get the same actions. Build-verified.

**Files:**
- Modify: `macos/Sources/Features/Command Palette/TerminalCommandPalette.swift` (add Leo command entries)
- Read first: that file + `CommandPalette.swift` to match the entry/command model (each entry has a title + action closure).

- [ ] **Step 1: Add the entries**

Following the existing entry construction in `TerminalCommandPalette.swift`, append entries that route to the same controller/store actions:

```swift
// Leo integration commands (Phase 4).
CommandPaletteEntry(title: "Leo: Toggle Sidebar") {
    (NSApp.delegate as? AppDelegate)?.toggleLeoSidebar(nil)
}
CommandPaletteEntry(title: "Leo: New Agent…") {
    controller.presentSpawnSheet()
}
CommandPaletteEntry(title: "Leo: New Terminal Cell") {
    controller.addCell(source: .pty)
}
```

Use the exact entry type/initializer the file already defines (it may be named differently, e.g. `Ghostty.Command` or a local struct). Match the established shape — do not invent a new entry type. `controller` is whatever the palette already holds as its terminal controller reference; reuse it.

- [ ] **Step 2: Build**

Run: `nu macos/build.nu`
Expected: builds clean.

- [ ] **Step 3: Commit**

```bash
git add "macos/Sources/Features/Command Palette/TerminalCommandPalette.swift" macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): command-palette entries for sidebar/spawn/new-cell"
```

---

### Task 14: Restore wiring + dead-cell rendering on launch

Tie boards to windows: on launch, load boards, reconcile against the live daemon, recreate cells (real surface for attached agents/pty, `DeadCellView` for dead ones), and persist on board mutation.

**Files:**
- Modify: `macos/Sources/Features/Terminal/BaseTerminalController.swift` (board save on `addCell`/`closeCell`; restore on init)
- Modify: `macos/Sources/Features/Grid/TerminalGridView.swift` (render `DeadCellView` for cells whose registry source is a dead agent)
- Create: `macos/Sources/Features/Leo/BoardSession.swift` (glue: controller ↔ board snapshot ↔ store)
- Create: `macos/Tests/Leo/BoardSessionTests.swift` (pure snapshot/restore-plan logic)
- Add to Xcode targets.

- [ ] **Step 1: Write the failing test (pure restore-plan logic)**

```swift
// macos/Tests/Leo/BoardSessionTests.swift
import Testing
import Foundation
@testable import Ghostty

struct BoardSessionTests {
    @Test func restorePlanAttachesLiveAndDeadensMissing() {
        let board = Board(name: "w", cells: [
            BoardCell(source: .agent(name: "alive"), lastKnownAgent: .init(name: "alive", repo: "x/alive")),
            BoardCell(source: .agent(name: "gone"), lastKnownAgent: .init(name: "gone", repo: "x/gone")),
            BoardCell(source: .pty)
        ])
        let live = [Agent(name: "alive", template: "c", repo: "x/alive", workspace: "/w", status: .running, startedAt: "t", env: [:])]
        let plan = BoardSession.restorePlan(board: board, liveAgents: live)
        #expect(plan.filter { $0.isDead }.count == 1)
        #expect(plan.filter { !$0.isDead }.map(\.source) == [.agent(name: "alive"), .pty])
    }

    @Test func snapshotCapturesSourcesInOrder() {
        let plan = [
            BoardSession.PlannedCell(source: .agent(name: "a"), snapshot: .init(name: "a", repo: "x/a"), isDead: false),
            BoardSession.PlannedCell(source: .pty, snapshot: nil, isDead: false)
        ]
        let board = BoardSession.snapshot(name: "w", from: plan)
        #expect(board.cells.map(\.source) == [.agent(name: "a"), .pty])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `... -only-testing:GhosttyTests/BoardSessionTests`
Expected: FAIL — `BoardSession` undefined.

- [ ] **Step 3: Implement the pure glue**

```swift
// macos/Sources/Features/Leo/BoardSession.swift
import Foundation

/// Pure planning helpers that translate between a persisted `Board` and the
/// cells a controller should create. Kept free of AppKit so it is testable.
enum BoardSession {
    /// A cell the controller should materialize on restore.
    struct PlannedCell: Equatable {
        let source: CellSource
        let snapshot: AgentSnapshot?
        /// True when the agent is gone — render `DeadCellView` instead of a surface.
        let isDead: Bool
    }

    /// Decide, per saved cell, whether to attach a live surface or show a dead cell.
    static func restorePlan(board: Board, liveAgents: [Agent]) -> [PlannedCell] {
        let reconciled = board.reconciled(against: liveAgents)
        return reconciled.cells.map { cell in
            PlannedCell(source: cell.source,
                        snapshot: cell.lastKnownAgent,
                        isDead: cell.liveness == .dead)
        }
    }

    /// Build a persistable board from the current planned/live cells.
    static func snapshot(name: String, from cells: [PlannedCell]) -> Board {
        Board(name: name, cells: cells.map {
            BoardCell(source: $0.source, lastKnownAgent: $0.snapshot)
        })
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `... -only-testing:GhosttyTests/BoardSessionTests`
Expected: PASS (both tests).

- [ ] **Step 5: Wire persistence into the controller**

In `BaseTerminalController`, add a `BoardStore` + a debounced save invoked from `addCell`/`closeCell`. On window/controller init, load the matching board, call `BoardSession.restorePlan` against `store.agents` (refresh first), and for each planned cell either `addCell(source:)` (attached) or register it as a dead cell (record source in `cellRegistry`, mark a parallel `deadCells: Set<UUID>` so the grid renders `DeadCellView`). Use a single board per window for Phase 4; key it by a stable window/tab id or just persist one board for now.

```swift
private let boardStore = BoardStore()
private var saveWorkItem: DispatchWorkItem?

/// Persist the current board after a short debounce.
func scheduleBoardSave(name: String = "default") {
    saveWorkItem?.cancel()
    let item = DispatchWorkItem { [weak self] in
        guard let self else { return }
        let planned = Array(self.surfaceTree).map { view -> BoardSession.PlannedCell in
            let source = self.cellRegistry.source(for: view.uuid)
            let snap: AgentSnapshot? = { if case .agent(let n) = source { return AgentSnapshot(name: n, repo: "") } else { return nil } }()
            return .init(source: source, snapshot: snap, isDead: false)
        }
        try? self.boardStore.save([BoardSession.snapshot(name: name, from: planned)])
    }
    saveWorkItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: item)
}
```

Call `scheduleBoardSave()` at the end of `addCell` and `closeCell` (Task 7 methods).

- [ ] **Step 6: Render dead cells in the grid**

In `TerminalGridView`, the placed cells come from the surface tree. Dead cells have no surface, so they need a parallel placeholder list from the controller (`deadCells` snapshots + their slot). Simplest Phase 4 approach: keep dead cells as real surfaces is wrong (no agent), so instead render dead placeholders as extra `GridLayout` cells. Add an overlay branch: for any placed cell whose `cellRegistry.source` resolves to an agent that the store reports not-running, draw `DeadCellView` over the surface position with respawn/remove wired to `store.spawn` + `closeCell`. Confirm the exact plumbing while implementing — the GridLayout currently keys on `SurfaceView`; you may model a dead cell as a lightweight placeholder type the layout can also place (generalize `GridLayout`'s element or add a sibling overlay list). Keep the change minimal and covered by a build + manual check.

- [ ] **Step 7: Build + targeted tests**

Run: `nu macos/build.nu` then `nu macos/build.nu --action test`
Expected: app builds; all GhosttyTests Leo suites pass.

- [ ] **Step 8: Commit**

```bash
git add macos/Sources/Features/Leo/BoardSession.swift macos/Tests/Leo/BoardSessionTests.swift macos/Sources/Features/Terminal/BaseTerminalController.swift macos/Sources/Features/Grid/TerminalGridView.swift macos/Ghostty.xcodeproj/project.pbxproj
git commit -m "feat(leo): board save/restore with dead-cell reconciliation"
```

---

### Task 15: Full build, suite, and manual E2E handoff

**Files:** none (verification + docs).

- [ ] **Step 1: Full build**

Run: `nu macos/build.nu`
Expected: clean build of the app bundle.

- [ ] **Step 2: Full unit suite**

Run: `nu macos/build.nu --action test`
Expected: PASS — all GhosttyTests including the new Leo suites (LeoError, LeoModels, LeoHTTP, LeoAgentStore, CellRegistry, Board, BoardStore, BoardSession, CellSourceCodable).

- [ ] **Step 3: Format + lint**

Run: `swiftlint lint --strict --fix` (then re-run `--strict` to confirm zero violations) and `zig fmt .` is N/A (no Zig changes). Re-build if lint auto-fixed anything.

- [ ] **Step 4: Manual E2E checklist (Evan, on Dionysus — daemon socket is local there)**

Document results for each:
- Sidebar toggles; lists the live agents from `leo agent list` with running/stopped dots; "daemon offline" shows when the daemon is stopped.
- Click an agent → a cell appears on the board and renders the live agent (Phase 3 render path); checkmark shows it's on-board.
- New Agent → pick template + repo → spawns → lands on the board.
- Close a cell (⌘W / detach) → cell goes away, `leo agent list` still shows the agent running.
- Stop agent (context menu) → agent transitions to stopped in the roster.
- Quit + relaunch → saved board restores; an agent killed while closed shows as a dead cell with working Respawn/Remove.
- Command palette: "Leo: Toggle Sidebar / New Agent / New Terminal Cell" all work.

- [ ] **Step 5: Update status memory + finish the branch**

Update memory `leo-project-status` to mark Phase 4 done (sidebar/palette, daemon socket transport, board save/restore, dead-cell restore) with the verify path. Then use `superpowers:finishing-a-development-branch` to decide merge/PR (the repo merges phases to `main` after manual verification — do not merge before Evan's E2E pass).

---

## Self-Review

**Spec coverage** (design doc §-by-§):
- Transport (socket, no token, templates via CLI) → Tasks 1–4. ✓
- Sidebar + palette discovery → Tasks 11, 13. ✓
- Spawn/attach/detach/stop lifecycle (model A) → Tasks 5, 7, 11, 12. ✓
- Board model + persistence + dead-cell restore → Tasks 8, 9, 10, 14. ✓
- Cell-ownership reuse (SplitTree) + registry → Tasks 6, 7. ✓
- Error handling / clean degradation → `LeoError` (Task 0), store `.offline` (Task 5), sidebar "daemon offline" (Task 11). ✓
- Testing (transport codec, store, board, reconciliation) → Tasks 1,3,5,8,9,14 unit; Task 15 manual. ✓
- Deferred (status dots, multi-window) → explicitly out of scope; not planned. ✓

**Placeholder scan:** Tasks 4, 7(step5), 11, 12, 13, 14(step6) intentionally say "match the existing idiom / confirm the accessor" because they touch AppKit/SwiftUI integration points whose exact local API must be read at implementation time; each names the specific file and symbol to confirm against, with concrete code to adapt. These are integration instructions, not unfilled TBDs. All pure-logic tasks (0,1,2,3,5,6,8,9,14-logic) have complete test + impl code.

**Type consistency:** `LeoDaemon` methods (Task 2) match `MockLeoDaemon` (Task 2) and `LeoSocketClient` (Task 4) and `LeoAgentStore` calls (Task 5). `CellSource` Codable shape (Task 6) used by `BoardCell` (Task 8) and `BoardStore` (Task 9). `CellRegistry` keys on `UUID`/`SurfaceView.ID` — Task 7 Step 5 flags the one place to confirm the key type matches the layout. `Board.reconciled` / `CellLiveness` (Task 8) consumed by `BoardSession.restorePlan` (Task 14). `AgentSpawnRequest` (Task 2) used by spawn sheet (Task 12) and socket client (Task 4). Consistent.
