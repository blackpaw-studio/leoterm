import Foundation
@testable import Ghostty

// Shared forward-launcher test doubles used by LeoHostRegistryTests and
// LeoSidebarModelTests. Both suites need a fake `ForwardHandle` that can yield a
// canned socket line (keeping its stream open so the forward "stays alive") and
// signal teardown via `onTerminate`, plus a `ForwardLauncher` that builds one.
// Keeping a single non-private definition avoids the two suites drifting apart.

/// A fake `ForwardHandle` whose `lines` stream is supplied by the test and whose
/// `terminate()` invokes an optional `onTerminate` callback so tests can observe
/// teardown.
struct FakeForwardHandle: ForwardHandle {
    let lines: AsyncStream<String>
    let onTerminate: @Sendable () -> Void

    init(lines: AsyncStream<String>, onTerminate: @escaping @Sendable () -> Void = {}) {
        self.lines = lines
        self.onTerminate = onTerminate
    }

    func terminate() { onTerminate() }
}

/// A fake `ForwardLauncher` that defers to a closure to build each handle.
struct FakeForwardLauncher: ForwardLauncher {
    let make: @Sendable ([String]) async -> ForwardHandle
    func launch(args: [String]) async -> ForwardHandle { await make(args) }
}
