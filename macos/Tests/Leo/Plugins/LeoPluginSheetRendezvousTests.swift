import Foundation
import Testing

@testable import Ghostty

@MainActor
struct LeoPluginSheetRendezvousTests {
    private func settle() async { for _ in 0..<20 { await Task.yield() } }

    @Test func theFirstFinishWinsAndCleanupRunsOnce() async {
        let rendezvous = LeoPluginSheetRendezvous<String>()
        var cleanups = 0
        rendezvous.onFinish { cleanups += 1 }
        let waiter = Task { await rendezvous.wait() }
        await settle()
        rendezvous.finish("first")
        rendezvous.finish("second")
        #expect(await waiter.value == "first")
        #expect(cleanups == 1)
    }

    @Test func aWindowThatClosesWithoutAnAnswerResumesTheWaiterAsACancel() async {
        let rendezvous = LeoPluginSheetRendezvous<String>()
        let waiter = Task { await rendezvous.wait() }
        await settle()
        rendezvous.finish(nil)   // what the parent's or sheet's willClose does
        #expect(await waiter.value == nil)
        #expect(rendezvous.isDone)
    }

    @Test func cancellingTheAwaitingTaskEndsTheSheetAndResumes() async {
        let rendezvous = LeoPluginSheetRendezvous<String>()
        var cleaned = false
        rendezvous.onFinish { cleaned = true }
        let waiter = Task { await rendezvous.wait() }
        await settle()
        waiter.cancel()
        #expect(await waiter.value == nil)
        #expect(cleaned)
    }

    @Test func finishingBeforeWaitingStillAnswersAndStillCleansUp() async {
        let rendezvous = LeoPluginSheetRendezvous<Int>()
        rendezvous.finish(7)
        var cleaned = false
        rendezvous.onFinish { cleaned = true }
        #expect(await rendezvous.wait() == 7)
        #expect(cleaned)
    }
}
