import Foundation
import Testing

@testable import Ghostty

/// Task 2 has no palette UI yet: `LeoPassthroughPicker` is the temporary
/// presenter wired into `LeoNewSurfaceRouter` so intercepted gestures still
/// resolve to *something* (a plain shell) instead of hanging forever.
@MainActor struct LeoPassthroughPickerTests {
    @Test func presentResolvesToPlainShell() async {
        var plainShellCalls: [LeoSurfaceRequest] = []
        var attachCalls = 0
        let router = LeoNewSurfaceRouter(
            attach: { _, _ in attachCalls += 1; return .success(()) },
            openPlainShell: { request in plainShellCalls.append(request); return .success(()) },
            presentSpawn: { _, complete in complete(nil) }
        )
        let picker = LeoPassthroughPicker(router: router)
        let request = LeoSurfaceRequest(origin: LeoWindowID(), disposition: .placeholder)
        router.begin(request)

        picker.present(request: request)
        // `present` fires a Task; poll briefly rather than assuming one
        // runloop turn is enough (avoids a flaky fixed sleep).
        for _ in 0..<200 where plainShellCalls.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }

        #expect(plainShellCalls == [request])
        #expect(attachCalls == 0)
    }
}
