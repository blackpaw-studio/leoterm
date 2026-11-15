import Foundation
import Testing

@testable import LeoKit

/// The task routes of the config API (run, history, log, prompt, cron
/// preview): their bodies decoded, and the requests the client sends.
struct LeoTaskAPITests {
    private static func client(prefix: String, _ transport: ConfigRecordingTransport) -> LeoConfigHTTPClient {
        LeoConfigHTTPClient(prefix: prefix, transport: transport)
    }

    // MARK: bodies

    @Test func historyDecodesTheGoldenEntries() throws {
        let runs = try LeoConfigFixtures.decode([LeoTaskRun].self, "task_history")

        let run = try #require(runs.first)
        #expect(run.task == "heartbeat")
        #expect(run.logFile == "heartbeat-1.jsonl")
        #expect(run.exitCode == 0)
        #expect(run.durationMs == 1500)
        #expect(run.succeeded == true)
        #expect(run.startedAt == Date(timeIntervalSince1970: 1_792_742_400))
        #expect(run.id == "heartbeat-1.jsonl")
    }

    @Test func aRunWithoutAnExitCodeHasNoOutcomeAndAnIdFromItsStart() throws {
        let body = #"{"ok": true, "data": [{"task": "t", "started_at": "2026-10-23T08:00:00.250Z"}]}"#
        let run = try #require(try LeoDaemonEnvelope<[LeoTaskRun]>.decode(Data(body.utf8)).value().first)

        #expect(run.succeeded == nil)
        #expect(run.logFile.isEmpty)
        #expect(run.startedAt != nil)
        #expect(run.id == "t@2026-10-23T08:00:00.250Z")
    }

    @Test func promptDecodesItsOwnRevisionAndFiles() throws {
        let prompt = try LeoConfigFixtures.decode(LeoTaskPrompt.self, "prompt")

        #expect(prompt.file == "heartbeat.md")
        #expect(prompt.files == ["heartbeat.md"])
        #expect(prompt.content == "Check the thing.\n")
        #expect(prompt.revision == LeoTaskPrompt.revision(of: prompt.content))
    }

    @Test func aSavedPromptAnswersTheNewRevision() throws {
        let saved = try LeoConfigFixtures.decode(LeoTaskPromptWrite.self, "prompt_put")

        #expect(saved.file == "heartbeat.md")
        #expect(saved.revision.hasPrefix("sha256:"))
    }

    @Test func aLongLogComesBackTruncated() throws {
        let log = try LeoConfigFixtures.decode(LeoTaskLog.self, "task_log")

        #expect(log.truncated)
        #expect(log.file == "heartbeat-1.jsonl")
        #expect(log.text.hasPrefix("{"))
    }

    @Test func aLogWithoutTheFlagIsNotTruncated() throws {
        let body = #"{"ok": true, "data": {"file": "t-1.log", "text": "hi"}}"#
        #expect(try !LeoDaemonEnvelope<LeoTaskLog>.decode(Data(body.utf8)).value().truncated)
    }

    @Test func cronPreviewDecodesValidAndInvalid() throws {
        let valid = try LeoConfigFixtures.decode(LeoCronPreview.self, "cron_preview")
        #expect(valid.valid)
        #expect(valid.description == "Daily at 3:00 AM")

        let body = #"{"ok": true, "data": {"valid": false, "description": "", "error": "expected 5 fields, got 3"}}"#
        let invalid = try LeoDaemonEnvelope<LeoCronPreview>.decode(Data(body.utf8)).value()
        #expect(!invalid.valid)
        #expect(invalid.error == "expected 5 fields, got 3")
    }

    @Test func aRunStartDecodes() throws {
        let started = try LeoConfigFixtures.decode(LeoTaskRunStart.self, "task_run")
        #expect(started.name == "heartbeat")
        #expect(started.status == "started")
    }

    // MARK: routes

    @Test(arguments: LeoConfigClientTests.prefixes)
    func theTaskRoutes(prefix: String) async throws {
        let transport = ConfigRecordingTransport { request in
            switch (request.method, request.path.split(separator: "?")[0].split(separator: "/").last) {
            case ("POST", _): "task_run"
            case (_, "history"): "task_history"
            case (_, "log"): "task_log"
            case ("PUT", _): "prompt_put"
            case (_, "prompt"): "prompt"
            default: "cron_preview"
            }
        }
        let client = Self.client(prefix: prefix, transport)

        _ = try await client.runTask("my task")
        _ = try await client.taskHistory("my task", limit: 20)
        _ = try await client.taskLog("my task", file: "my task-1.jsonl")
        _ = try await client.taskPrompt("my task")
        _ = try await client.saveTaskPrompt("my task", content: "Do it.\n", ifMatch: "sha256:p1")
        _ = try await client.cronPreview("*/5 * * * *")

        let requests = await transport.requests
        #expect(requests.map(\.method) == ["POST", "GET", "GET", "GET", "PUT", "GET"])
        #expect(requests.map(\.path) == [
            "\(prefix)/tasks/my%20task/run",
            "\(prefix)/tasks/my%20task/history?limit=20",
            "\(prefix)/tasks/my%20task/log?file=my%20task-1.jsonl",
            "\(prefix)/config/tasks/my%20task/prompt",
            "\(prefix)/config/tasks/my%20task/prompt",
            "\(prefix)/cron/preview?expr=%2A%2F5%20%2A%20%2A%20%2A%20%2A",
        ])
    }

    @Test func onlyThePromptSaveCarriesIfMatchAndABody() async throws {
        let transport = ConfigRecordingTransport { $0.method == "POST" ? "task_run" : "prompt_put" }
        let client = Self.client(prefix: "", transport)

        _ = try await client.runTask("t")
        _ = try await client.saveTaskPrompt("t", content: "Line\n\"quoted\"", ifMatch: "sha256:p1")

        let requests = await transport.requests
        #expect(requests[0].headers.isEmpty)
        #expect(requests[0].body == nil)
        #expect(requests[1].headers == ["If-Match": "sha256:p1"])
        let body = try #require(requests[1].body)
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == ["content": "Line\n\"quoted\""])
    }

    @Test func aLogFileCannotCarryAQueryOrPathIntoTheRoute() async throws {
        let transport = ConfigRecordingTransport(fixtures: ["task_log"])
        _ = try await Self.client(prefix: "", transport).taskLog("t", file: "../x&file=y#z")

        let path = try #require(await transport.requests.first?.path)
        #expect(path == "/tasks/t/log?file=..%2Fx%26file%3Dy%23z")
    }

    @Test func aStalePromptIsAConflictWithTheCurrentPromptRevision() async throws {
        let body = #"{"ok": false, "code": "revision_mismatch", "error": "stale", "data": {"revision": "sha256:p2"}}"#
        let client = Self.client(prefix: "", ConfigRecordingTransport(body: body, status: 409))

        await #expect(throws: LeoConfigError.conflict(currentRevision: "sha256:p2")) {
            _ = try await client.saveTaskPrompt("t", content: "x", ifMatch: "sha256:p1")
        }
    }

    @Test func aProtectedPromptFileIsAFieldErrorOnPromptFile() async throws {
        let body = #"{"ok": false, "code": "invalid", "error": "protected", "errors": [{"field": "prompt_file", "message": "leo.yaml cannot be a prompt"}]}"#
        let client = Self.client(prefix: "", ConfigRecordingTransport(body: body, status: 422))

        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "prompt_file", message: "leo.yaml cannot be a prompt")])) {
            _ = try await client.taskPrompt("t")
        }
    }

    @Test func aMissingLogIsADaemonNotFound() async throws {
        let body = #"{"ok": false, "code": "not_found", "error": "log file \"t-1\" not found"}"#
        let client = Self.client(prefix: "", ConfigRecordingTransport(body: body, status: 404))

        await #expect(throws: LeoDaemonError.self) { _ = try await client.taskLog("t", file: "t-1") }
    }
}
