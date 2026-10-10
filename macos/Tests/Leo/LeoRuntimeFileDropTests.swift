import AppKit
import Foundation
import Testing

@testable import Ghostty

@MainActor
struct LeoRuntimeFileDropTests {
    private final class State: @unchecked Sendable {
        var context: LeoTerminalFileDropContext?
        var requestedHosts: [LeoHostID] = []
        var accesses: [any LeoFileAccess] = []
        var inserted: [String] = []
        var accessError: LeoFileAccessError?
    }

    private func makeSurface() throws -> Ghostty.SurfaceView {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty.app)
        return Ghostty.SurfaceView(app, baseConfig: nil)
    }

    private func makeRuntime(_ state: State) -> LeoRuntime {
        LeoRuntime(
            daemon: FileDropUnusedDaemon(), cli: .recordingForTests(),
            activitySource: LeoSidebarActivitySource(events: { AsyncStream { $0.finish() } }, fetchState: { [] }),
            defaults: LeoInMemoryDefaults(), templateFetchRunner: LeoRecordingTemplateRunner(),
            terminalFileDropDependencies: LeoTerminalFileDropDependencies(
                context: { _ in state.context },
                makeAccess: { host in
                    state.requestedHosts.append(host)
                    if let error = state.accessError { throw error }
                    return state.accesses.removeFirst()
                },
                insertText: { _, text in state.inserted.append(text) }
            )
        )
    }

    private func pasteboard(_ urls: [URL]) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("leo-file-drop-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
        return pasteboard
    }

    private func context(host: LeoHostID = .local, workspace: String, generation: UInt64 = 1) -> LeoTerminalFileDropContext {
        LeoTerminalFileDropContext(
            identity: LeoAgentIdentity(host: host, name: "scratch"), workspace: workspace,
            attachmentGeneration: generation
        )
    }

    @Test func localAndRemoteAttachedRoutesUploadAndInsertOnlyWorkspacePaths() async throws {
        for host in [LeoHostID.local, .remote("work")] {
            let source = try LeoFileSandbox()
            let destination = try LeoFileSandbox()
            defer {
                source.cleanUp()
                destination.cleanUp()
            }
            let localPath = try source.file("two words.txt", "payload")
            let state = State()
            state.context = context(host: host, workspace: destination.root)
            state.accesses = [LeoFileAccessor.local()]
            let runtime = makeRuntime(state)
            let surface = try makeSurface()
            let board = pasteboard([URL(fileURLWithPath: localPath)])

            #expect(runtime.acceptsFileDrop(board, from: surface))
            #expect(runtime.performFileDrop(board, from: surface))
            await awaitCondition { !state.inserted.isEmpty }

            #expect(state.requestedHosts == [host])
            #expect(state.inserted == [Ghostty.Shell.escape(destination.path("two words.txt"))])
            #expect(!state.inserted[0].contains(source.root))
            #expect(try destination.contents("two words.txt") == "payload")
            runtime.shutdown()
        }
    }

    @Test func partialFailureInsertsOnlySuccessAndKeepsTheErrorVisible() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let clash = try source.file("clash.txt", "replacement")
        let good = try source.file("good.txt", "good")
        try destination.file("clash.txt", "keep")
        let state = State()
        state.context = context(workspace: destination.root)
        state.accesses = [LeoFileAccessor.local()]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: clash), URL(fileURLWithPath: good)]), from: surface))
        await awaitCondition { await MainActor.run { surface.leoFileDropStatus != .uploading(2) } }

        #expect(state.inserted == [destination.path("good.txt")])
        guard case .failed(let message) = surface.leoFileDropStatus else {
            Issue.record("expected persistent failure status")
            runtime.shutdown()
            return
        }
        #expect(message.contains("clash.txt"))
        #expect(try destination.contents("clash.txt") == "keep")
        runtime.shutdown()
    }

    @Test func plainShellLeavesTheDropForGhostty() throws {
        let state = State()
        let runtime = makeRuntime(state)
        let surface = try makeSurface()
        let board = pasteboard([URL(fileURLWithPath: "/tmp/a.txt")])

        #expect(!runtime.acceptsFileDrop(board, from: surface))
        #expect(!runtime.performFileDrop(board, from: surface))
        #expect(state.requestedHosts.isEmpty)
        runtime.shutdown()
    }

    @Test func accessorFactoryFailureIsShownAndInsertsNothing() async throws {
        let state = State()
        state.context = context(host: .remote("work"), workspace: "/workspace")
        state.accessError = .unavailable(reason: "SFTP unavailable")
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: "/tmp/a.txt")]), from: surface))
        await awaitCondition {
            await MainActor.run {
                if case .failed = surface.leoFileDropStatus { return true }
                return false
            }
        }

        guard case .failed(let message) = surface.leoFileDropStatus else {
            Issue.record("expected an accessor failure")
            runtime.shutdown()
            return
        }
        #expect(message.contains("SFTP unavailable"))
        #expect(state.inserted.isEmpty)
        runtime.shutdown()
    }

    @Test func sameAgentReattachedDuringUploadClosesAccessAndNeverGetsTheOldCompletion() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let path = try source.file("old.txt", "old")
        let gate = FileDropAccessGate()
        let access = FileDropGatedAccess(base: LeoFileAccessor.local(), gate: gate)
        let state = State()
        state.context = context(workspace: destination.root, generation: 1)
        state.accesses = [access]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()
        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: path)]), from: surface))
        await gate.waitUntilEntered()

        state.context = context(workspace: destination.root, generation: 2)
        runtime.terminalFileDropContextDidChange()
        await awaitCondition { await gate.isClosed }

        #expect(state.inserted.isEmpty)
        #expect(await gate.isClosed)
        runtime.shutdown()
    }

    @Test func overlappingDropsStayOrderedAndRetainEveryFailure() async throws {
        let source = try LeoFileSandbox()
        let destination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            destination.cleanUp()
        }
        let first = try source.file("first.txt", "first")
        let second = try source.file("second.txt", "second")
        let firstClash = try source.file("first-clash.txt", "replacement")
        let secondClash = try source.file("second-clash.txt", "replacement")
        try destination.file("first-clash.txt", "keep first")
        try destination.file("second-clash.txt", "keep second")
        let gate = FileDropAccessGate()
        let state = State()
        state.context = context(workspace: destination.root)
        state.accesses = [FileDropGatedAccess(base: LeoFileAccessor.local(), gate: gate), LeoFileAccessor.local()]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(
            pasteboard([URL(fileURLWithPath: first), URL(fileURLWithPath: firstClash)]), from: surface
        ))
        await gate.waitUntilEntered()
        #expect(runtime.performFileDrop(
            pasteboard([URL(fileURLWithPath: second), URL(fileURLWithPath: secondClash)]), from: surface
        ))

        try await Task.sleep(for: .milliseconds(50))
        #expect(state.requestedHosts.count == 1, "the second drop must remain queued")
        #expect(state.inserted.isEmpty)
        await gate.release()
        await awaitCondition { state.inserted.count == 2 }

        #expect(state.inserted == [destination.path("first.txt"), destination.path("second.txt")])
        guard case .failed(let message) = surface.leoFileDropStatus else {
            Issue.record("expected both queued failures to remain visible")
            runtime.shutdown()
            return
        }
        #expect(message.contains("first-clash.txt"))
        #expect(message.contains("second-clash.txt"))
        runtime.dismissTerminalFileDropError(from: surface)
        #expect(surface.leoFileDropStatus == nil)
        runtime.shutdown()
    }

    @Test func cancelBeforeTheOperationStartsNeverCreatesAnAccessor() throws {
        let state = State()
        state.context = context(workspace: "/old", generation: 1)
        state.accesses = [LeoFileAccessor.local()]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: "/tmp/old.txt")]), from: surface))
        state.context = context(workspace: "/new", generation: 2)
        runtime.terminalFileDropContextDidChange()

        #expect(state.requestedHosts.isEmpty)
        runtime.shutdown()
    }

    @Test func canceledOldOperationCannotClearTheNewOperationsAccessor() async throws {
        let source = try LeoFileSandbox()
        let oldDestination = try LeoFileSandbox()
        let newDestination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            oldDestination.cleanUp()
            newDestination.cleanUp()
        }
        let oldPath = try source.file("old.txt", "old")
        let newPath = try source.file("new.txt", "new")
        let oldGate = FileDropAccessGate()
        let newGate = FileDropAccessGate()
        let state = State()
        state.context = context(workspace: oldDestination.root, generation: 1)
        state.accesses = [
            FileDropGatedAccess(base: LeoFileAccessor.local(), gate: oldGate),
            FileDropGatedAccess(base: LeoFileAccessor.local(), gate: newGate),
        ]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: oldPath)]), from: surface))
        await oldGate.waitUntilEntered()
        state.context = context(workspace: newDestination.root, generation: 2)
        runtime.terminalFileDropContextDidChange()
        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: newPath)]), from: surface))
        await newGate.waitUntilEntered()
        await newGate.release()
        await awaitCondition { !state.inserted.isEmpty }

        #expect(state.inserted == [newDestination.path("new.txt")])
        #expect(try newDestination.contents("new.txt") == "new")
        runtime.shutdown()
    }

    @Test func completionUnderAChangedContextResetsAndDoesNotWedgeTheQueue() async throws {
        let source = try LeoFileSandbox()
        let oldDestination = try LeoFileSandbox()
        let newDestination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            oldDestination.cleanUp()
            newDestination.cleanUp()
        }
        let oldPath = try source.file("old.txt", "old")
        let newPath = try source.file("new.txt", "new")
        let gate = FileDropAccessGate()
        let state = State()
        state.context = context(workspace: oldDestination.root, generation: 1)
        state.accesses = [FileDropGatedAccess(base: LeoFileAccessor.local(), gate: gate), LeoFileAccessor.local()]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: oldPath)]), from: surface))
        await gate.waitUntilEntered()
        state.context = context(workspace: newDestination.root, generation: 2)
        await gate.release()
        await awaitCondition { await MainActor.run { surface.leoFileDropStatus != .uploading(1) } }
        #expect(surface.leoFileDropStatus == nil)
        #expect(state.inserted.isEmpty)

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: newPath)]), from: surface))
        await awaitCondition { !state.inserted.isEmpty }
        #expect(state.inserted == [newDestination.path("new.txt")])
        runtime.shutdown()
    }

    @Test func errorsFromAnOldContextDoNotLeakIntoTheNextAttachment() async throws {
        let source = try LeoFileSandbox()
        let oldDestination = try LeoFileSandbox()
        let newDestination = try LeoFileSandbox()
        defer {
            source.cleanUp()
            oldDestination.cleanUp()
            newDestination.cleanUp()
        }
        let clash = try source.file("clash.txt", "replacement")
        let good = try source.file("good.txt", "good")
        try oldDestination.file("clash.txt", "keep")
        let state = State()
        state.context = context(workspace: oldDestination.root, generation: 1)
        state.accesses = [LeoFileAccessor.local(), LeoFileAccessor.local()]
        let runtime = makeRuntime(state)
        let surface = try makeSurface()

        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: clash)]), from: surface))
        await awaitCondition {
            await MainActor.run {
                if case .failed = surface.leoFileDropStatus { return true }
                return false
            }
        }
        state.context = context(workspace: newDestination.root, generation: 2)
        #expect(runtime.performFileDrop(pasteboard([URL(fileURLWithPath: good)]), from: surface))
        await awaitCondition { !state.inserted.isEmpty }

        #expect(surface.leoFileDropStatus == nil)
        #expect(state.inserted == [newDestination.path("good.txt")])
        runtime.shutdown()
    }
}

private actor FileDropAccessGate {
    private var entered = false
    private var callCount = 0
    private var waiter: CheckedContinuation<Void, Error>?
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isClosed = false

    func enter() async throws {
        callCount += 1
        guard callCount == 1 else { return }
        entered = true
        enteredWaiters.forEach { $0.resume() }
        enteredWaiters = []
        try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }

    func close() {
        isClosed = true
        waiter?.resume(throwing: LeoFileAccessError.closed)
        waiter = nil
    }
}

private struct FileDropGatedAccess: LeoFileAccess {
    let base: any LeoFileAccess
    let gate: FileDropAccessGate

    func list(_ path: String) async throws -> [LeoFileEntry] { try await base.list(path) }
    func stat(_ path: String) async throws -> LeoFileStat { try await base.stat(path) }
    func homeDirectory() async throws -> String { try await base.homeDirectory() }
    func read(_ path: String, maxBytes: UInt64) async throws -> LeoFileContents { try await base.read(path, maxBytes: maxBytes) }
    func write(_ data: Data, to path: String, expecting expected: LeoFileVersion?) async throws -> LeoFileStat {
        try await base.write(data, to: path, expecting: expected)
    }
    func create(_ data: Data, at path: String) async throws -> LeoFileStat {
        try await gate.enter()
        return try await base.create(data, at: path)
    }
    func close() async {
        await gate.close()
        await base.close()
    }
}

private struct FileDropUnusedDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { fatalError() }
    func start(_ name: String) async throws { fatalError() }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { fatalError() }
    func restart(_ name: String) async throws -> LeoAgent { fatalError() }
    func reset(_ name: String) async throws { fatalError() }
    func setTemplate(_ name: String, template: String) async throws { fatalError() }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { fatalError() }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { fatalError() }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { fatalError() }
    func logs(_ name: String, lines: Int?) async throws -> String { fatalError() }
}
