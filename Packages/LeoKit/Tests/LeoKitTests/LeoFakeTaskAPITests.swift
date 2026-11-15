import Foundation
import Testing

@testable import LeoKit

struct LeoFakeTaskAPITests {
    private static func run(_ task: String, at second: Int, exit: Int = 0) -> LeoTaskRun {
        LeoTaskRun(task: task, startedAt: Date(timeIntervalSince1970: Double(second)), exitCode: exit, durationMs: 1000, logFile: "\(task)-\(second).jsonl")
    }

    private static func fake(protected: Set<String> = []) throws -> LeoFakeConfigClient {
        let schema = try LeoConfigFixtures.decode(LeoConfigSchema.self, "schema")
        let tasks = try LeoConfigFixtures.decode(LeoConfigCollection.self, "tasks").items
        return LeoFakeConfigClient(
            schema: schema, collections: ["tasks": tasks],
            tasks: LeoFakeTaskData(
                runs: ["heartbeat": [run("heartbeat", at: 300, exit: 1), run("heartbeat", at: 200), run("heartbeat", at: 100)]],
                logs: ["heartbeat-300.jsonl": "boom\n"],
                prompts: ["heartbeat.md": "Check the thing.\n", "notes.md": "Notes\n"], protectedPrompts: protected
            )
        )
    }

    // MARK: run, history, log

    @Test func runningATaskIsRecordedAndStarts() async throws {
        let fake = try Self.fake()

        let started = try await fake.runTask("heartbeat")

        #expect(started == LeoTaskRunStart(name: "heartbeat", status: "started"))
        #expect(await fake.calls.last == .runTask("heartbeat"))
    }

    @Test func runningAnUnknownTaskIsNotFound() async throws {
        let fake = try Self.fake()
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.runTask("nope") }
    }

    @Test func historyIsNewestFirstAndLimited() async throws {
        let fake = try Self.fake()

        #expect(try await fake.taskHistory("heartbeat", limit: 2).map(\.logFile) == ["heartbeat-300.jsonl", "heartbeat-200.jsonl"])
        #expect(try await fake.taskHistory("nightly", limit: 20).isEmpty)
    }

    @Test func aLogIsServedOnlyForTheTasksOwnFiles() async throws {
        let fake = try Self.fake()

        #expect(try await fake.taskLog("heartbeat", file: "heartbeat-300.jsonl").text == "boom\n")
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.taskLog("nightly", file: "heartbeat-300.jsonl") }
        await #expect(throws: LeoDaemonError.self) { _ = try await fake.taskLog("heartbeat", file: "heartbeat-999.jsonl") }
    }

    // MARK: prompt

    @Test func thePromptIsTheConfiguredFileWithItsOwnRevision() async throws {
        let fake = try Self.fake()

        let prompt = try await fake.taskPrompt("heartbeat")

        #expect(prompt.file == "heartbeat.md")
        #expect(prompt.content == "Check the thing.\n")
        #expect(prompt.files == ["heartbeat.md", "notes.md"])
        #expect(prompt.revision == LeoTaskPrompt.revision(of: "Check the thing.\n"))
    }

    @Test func aMissingPromptFileIsEmptyWithTheRevisionOfNothing() async throws {
        let fake = try Self.fake()

        let prompt = try await fake.taskPrompt("nightly")

        #expect(prompt.file == "prompts/nightly.md")
        #expect(prompt.content.isEmpty)
        #expect(prompt.revision == LeoTaskPrompt.revision(of: ""))
    }

    @Test func savingWritesTheFileCreatesItAndBumpsOnlyThePromptRevision() async throws {
        let fake = try Self.fake()
        let configRevision = try await fake.collection("tasks").revision
        let first = try await fake.taskPrompt("nightly")

        let saved = try await fake.saveTaskPrompt("nightly", content: "Review.\n", ifMatch: first.revision)

        let after = try await fake.taskPrompt("nightly")
        #expect(saved.revision == after.revision)
        #expect(after.content == "Review.\n")
        #expect(after.files.contains("prompts/nightly.md"))
        #expect(try await fake.collection("tasks").revision == configRevision)
    }

    @Test func aStalePromptRevisionIsAConflictWithTheCurrentOne() async throws {
        let fake = try Self.fake()
        let stale = try await fake.taskPrompt("heartbeat").revision
        await fake.externalPromptChange(file: "heartbeat.md", content: "Someone else.\n")

        await #expect(throws: LeoConfigError.conflict(currentRevision: LeoTaskPrompt.revision(of: "Someone else.\n"))) {
            _ = try await fake.saveTaskPrompt("heartbeat", content: "Mine.\n", ifMatch: stale)
        }
        #expect(try await fake.taskPrompt("heartbeat").content == "Someone else.\n")
    }

    @Test func aPromptSaveWithoutIfMatchIsRefused() async throws {
        let fake = try Self.fake()
        await #expect(throws: LeoConfigError.revisionRequired) { _ = try await fake.saveTaskPrompt("heartbeat", content: "x", ifMatch: "") }
    }

    @Test func choosingAnotherFileIsATaskUpdateOfPromptFile() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("tasks").revision

        _ = try await fake.update("tasks", name: "heartbeat", patch: ["prompt_file": .string("notes.md")], ifMatch: revision)

        let prompt = try await fake.taskPrompt("heartbeat")
        #expect(prompt.file == "notes.md")
        #expect(prompt.content == "Notes\n")
    }

    @Test func aProtectedPromptFileIsRejectedOnPromptFile() async throws {
        let fake = try Self.fake(protected: ["heartbeat.md"])
        let expected = LeoConfigError.invalid([LeoConfigFieldError(field: "prompt_file", message: "heartbeat.md is not available as a prompt")])

        await #expect(throws: expected) { _ = try await fake.taskPrompt("heartbeat") }
        await #expect(throws: expected) { _ = try await fake.saveTaskPrompt("heartbeat", content: "x", ifMatch: "sha256:r") }
        #expect(try await fake.taskPrompt("nightly").files == ["notes.md"])
    }

    // MARK: cron

    @Test func cronPreviewReadsFiveFields() async throws {
        let fake = try Self.fake()

        #expect(try await fake.cronPreview("0 3 * * *").valid)
        let invalid = try await fake.cronPreview("0 3 *")
        #expect(!invalid.valid)
        #expect(invalid.error == "expected 5 fields, got 3")
    }

    // MARK: add

    @Test func addingATaskNeedsAScheduleAndDefaultsItsPromptFileAndEnabled() async throws {
        let fake = try Self.fake()
        let revision = try await fake.collection("tasks").revision

        await #expect(throws: LeoConfigError.invalid([LeoConfigFieldError(field: "schedule", message: "schedule is required")])) {
            _ = try await fake.add("tasks", name: "weekly", values: [:], ifMatch: revision)
        }
        let added = try await fake.add("tasks", name: "weekly", values: ["schedule": .string("0 9 * * 1")], ifMatch: revision)

        let item = try #require(added.item)
        #expect(item.values["prompt_file"] == .string("prompts/weekly.md"))
        #expect(item.values["enabled"] == .bool(false))
        #expect(item.values["schedule"] == .string("0 9 * * 1"))
    }
}
