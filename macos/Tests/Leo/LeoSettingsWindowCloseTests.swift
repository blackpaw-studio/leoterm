import AppKit
import Foundation
import Testing

@testable import Ghostty
@testable import LeoKit

/// Closing the Settings window with edits in the machine list and in a config
/// pane asks about each, one after the other, and never drops either unasked.
@MainActor struct LeoSettingsWindowCloseTests {
    private static let machinesTitle = "Save changes to your machines?"
    private static let panesTitle = "Discard unsaved settings changes?"

    /// Answers each prompt, later than the call that asked, as a sheet does.
    @MainActor private final class ScriptedPrompting: LeoSettingsPrompting {
        private(set) var asked: [String] = []
        private var answers: [Int]

        init(answers: [Int]) { self.answers = answers }

        func ask(_ prompt: LeoSettingsPrompt, on window: NSWindow, answer: @escaping @MainActor (Int) -> Void) {
            asked.append(prompt.title)
            let choice = answers.isEmpty ? prompt.buttons.count - 1 : answers.removeFirst()
            Task { @MainActor in answer(choice) }
        }
    }

    @MainActor private final class Pane: LeoSettingsPane {
        var hasUnsavedChanges = true
        private(set) var discards = 0
        func discardChanges() { hasUnsavedChanges = false; discards += 1 }
        func reload(using client: any LeoConfigClient) async {}
    }

    private func controller(answers: [Int], machinesDirty: Bool, paneDirty: Bool) -> (LeoSettingsWindowController, ScriptedPrompting, Pane) {
        let prompting = ScriptedPrompting(answers: answers)
        let controller = LeoSettingsWindowController(
            registry: .isolatedForTesting(), clients: FakeMachineClients(), defaults: LeoInMemoryDefaults(),
            selectedHost: { nil }, prompting: prompting
        )
        controller.show()
        let pane = Pane()
        pane.hasUnsavedChanges = paneDirty
        controller.target?.register(pane, for: .config("templates"))
        if machinesDirty { controller.model?.addHost() }
        return (controller, prompting, pane)
    }

    @Test func machineAndPaneEditsEachGetAnAnswerBeforeTheWindowCloses() async {
        // Discard the machine list edits, then cancel at the pane question.
        let (controller, prompting, pane) = controller(answers: [1, 1], machinesDirty: true, paneDirty: true)
        controller.window?.performClose(nil)
        await awaitCondition { @MainActor in prompting.asked.count == 2 }

        #expect(prompting.asked == [Self.machinesTitle, Self.panesTitle])
        #expect(controller.window?.isVisible == true)
        #expect(pane.discards == 0)
        #expect(pane.hasUnsavedChanges)
        controller.window?.close()
    }

    @Test func discardingBothClosesTheWindowAndDropsThePaneEdits() async {
        let (controller, prompting, pane) = controller(answers: [1, 0], machinesDirty: true, paneDirty: true)
        controller.window?.performClose(nil)
        await awaitCondition { @MainActor in controller.window?.isVisible == false }

        #expect(prompting.asked == [Self.machinesTitle, Self.panesTitle])
        #expect(pane.discards == 1)
    }

    @Test func cancellingTheMachineQuestionAsksNothingMore() async {
        let (controller, prompting, pane) = controller(answers: [2], machinesDirty: true, paneDirty: true)
        controller.window?.performClose(nil)
        await awaitCondition { @MainActor in prompting.asked.count == 1 }
        for _ in 0..<10 { await Task.yield() }

        #expect(prompting.asked == [Self.machinesTitle])
        #expect(controller.window?.isVisible == true)
        #expect(pane.discards == 0)
        controller.window?.close()
    }

    @Test func paneEditsAloneAskOnce() async {
        let (controller, prompting, pane) = controller(answers: [0], machinesDirty: false, paneDirty: true)
        controller.window?.performClose(nil)
        await awaitCondition { @MainActor in controller.window?.isVisible == false }

        #expect(prompting.asked == [Self.panesTitle])
        #expect(pane.discards == 1)
    }

    @Test func nothingToSaveClosesWithoutAsking() async {
        let (controller, prompting, _) = controller(answers: [], machinesDirty: false, paneDirty: false)
        controller.window?.performClose(nil)
        await awaitCondition { @MainActor in controller.window?.isVisible == false }

        #expect(prompting.asked.isEmpty)
    }
}
