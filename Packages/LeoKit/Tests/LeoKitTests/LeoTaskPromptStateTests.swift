import Foundation
import Testing

@testable import LeoKit

struct LeoTaskPromptStateTests {
    private static func loaded(file: String = "heartbeat.md", content: String = "ping", text: String? = nil) -> LeoTaskPromptState {
        let document = LeoTaskPrompt(revision: "p1", file: file, files: [file], content: content)
        return LeoTaskPromptState(phase: .loaded, file: file, document: document, text: text ?? content)
    }

    @Test func configuredFileMovedAsks() {
        var prompt = Self.loaded(text: "edited")

        let step1 = prompt.saveCheck(configuredFile: "heartbeat.md")
        #expect(step1 == .proceed)
        #expect(prompt.confirmation == nil)

        let step2 = prompt.saveCheck(configuredFile: "other.md")
        #expect(step2 == .askFileChanged)
        #expect(prompt.confirmation == .fileChanged("other.md"))
    }

    @Test func conflictOnSameFileIsConflict() {
        var prompt = Self.loaded(text: "edited")
        let served = LeoTaskPrompt(revision: "p2", file: "heartbeat.md", files: ["heartbeat.md"], content: "theirs")

        prompt.conflictOutcome(served: served, current: "p2")

        #expect(prompt.conflict == "p2")
        #expect(prompt.confirmation == nil)
    }

    @Test func conflictAfterFileMovedAsks() {
        var prompt = Self.loaded(text: "edited")
        let served = LeoTaskPrompt(revision: "p9", file: "other.md", files: ["other.md"], content: "theirs")

        prompt.conflictOutcome(served: served, current: "p9")

        #expect(prompt.confirmation == .fileChanged("other.md"))
        #expect(prompt.conflict == nil)
    }

    @Test func aConflictWithNoServedFileIsStillAConflict() {
        var prompt = Self.loaded(text: "edited")

        prompt.conflictOutcome(served: nil, current: "p2")

        #expect(prompt.conflict == "p2")
    }

    @Test func formSaveRepointingWhileDirtyAsks() {
        var prompt = Self.loaded(text: "edited")

        let step3 = prompt.formSaveAllowed(patch: ["model": .string("opus")])
        #expect(step3)
        let step4 = prompt.formSaveAllowed(patch: ["prompt_file": .string("heartbeat.md")])
        #expect(step4)
        #expect(prompt.confirmation == nil)

        let step5 = prompt.formSaveAllowed(patch: ["prompt_file": .string("other.md")])
        #expect(!step5)
        #expect(prompt.confirmation == .saveWithFile("other.md"))
    }

    @Test func formSaveRepointingWhileCleanProceeds() {
        var prompt = Self.loaded()

        let step6 = prompt.formSaveAllowed(patch: ["prompt_file": .string("other.md")])
        #expect(step6)
        #expect(prompt.confirmation == nil)
    }

    @Test func cleanPromptFollowsNewFile() {
        var prompt = Self.loaded()

        let step7 = prompt.itemsChanged(configuredFile: "heartbeat.md")
        #expect(step7 == .none)
        let step8 = prompt.itemsChanged(configuredFile: "other.md")
        #expect(step8 == .reload)
        #expect(prompt.confirmation == nil)
        var idle = LeoTaskPromptState()
        let idleChange = idle.itemsChanged(configuredFile: "other.md")
        #expect(idleChange == .none)
    }

    @Test func dirtyPromptKeepsItsTextAndAsksAboutTheNewFile() {
        var prompt = Self.loaded(text: "edited")

        let step9 = prompt.itemsChanged(configuredFile: "other.md")
        #expect(step9 == .none)
        #expect(prompt.confirmation == .fileChanged("other.md"))
        #expect(prompt.text == "edited")

        let step10 = prompt.itemsChanged(configuredFile: "heartbeat.md")
        #expect(step10 == .none)
        #expect(prompt.confirmation == nil)
    }

    @Test func savedRecordsTheFileAndClearsTheConflict() {
        var prompt = Self.loaded(text: "edited")
        prompt.conflict = "p2"

        prompt.saved(LeoTaskPromptWrite(revision: "p3", file: "heartbeat.md"), sent: "edited")

        #expect(prompt.document?.content == "edited")
        #expect(prompt.document?.revision == "p3")
        #expect(prompt.conflict == nil)
        #expect(!prompt.isDirty)
    }

    @Test func discardingEditsRestoresTheServedText() {
        var prompt = Self.loaded(text: "edited")
        prompt.conflict = "p2"
        prompt.error = "boom"
        prompt.confirmation = .fileChanged("other.md")

        prompt.discardEdits()

        #expect(prompt.text == "ping")
        #expect(prompt.conflict == nil && prompt.error == nil && prompt.confirmation == nil)
    }

    @Test func toggleOverrideClearsAfterLastPending() {
        let item = LeoConfigItem(name: "nightly", values: ["enabled": .bool(false)])
        var toggles = LeoTaskToggleOverrides()
        #expect(!toggles.isEnabled(item))

        toggles.begin("nightly", enabled: true)
        toggles.begin("nightly", enabled: false)
        toggles.begin("nightly", enabled: true)
        #expect(toggles.isEnabled(item))

        toggles.finish("nightly")
        toggles.finish("nightly")
        #expect(toggles.isEnabled(item))

        toggles.finish("nightly")
        #expect(!toggles.isEnabled(item))
        #expect(toggles == LeoTaskToggleOverrides())
    }

    @Test func logTailKeepsLastBytesOnLineBoundary() {
        let lines = (1...50).map { "line \($0)" }
        let log = LeoTaskLog(file: "run.log", text: lines.joined(separator: "\n") + "\n")

        let tail = log.tail(maxBytes: 40)

        #expect(tail.truncated)
        #expect(tail.text.utf8.count <= 40)
        #expect(tail.text.hasPrefix("line "))
        #expect(tail.text.hasSuffix("line 50\n"))
        #expect(log.text.hasSuffix(tail.text))
        #expect(tail.file == "run.log")
    }

    @Test func aShortLogIsKeptWhole() {
        let log = LeoTaskLog(file: "run.log", text: "a\nb\n", truncated: false)

        #expect(log.tail(maxBytes: 4) == log)
    }

    @Test func aLongLastLineKeepsItsEndOnACharacterBoundary() {
        let log = LeoTaskLog(file: "run.log", text: String(repeating: "é", count: 20) + "\n")

        let tail = log.tail(maxBytes: 9)

        #expect(tail.truncated)
        #expect(tail.text.utf8.count <= 9)
        #expect(!tail.text.isEmpty)
        #expect(tail.text.hasSuffix("é\n"))
    }

    @Test func aLogTheDaemonAlreadyCutStaysMarkedCut() {
        let log = LeoTaskLog(file: "run.log", text: "a\nb\n", truncated: true)

        #expect(log.tail(maxBytes: 100).truncated)
    }
}
