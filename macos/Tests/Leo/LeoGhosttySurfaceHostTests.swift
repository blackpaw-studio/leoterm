import Testing

@testable import Ghostty

@MainActor struct LeoGhosttySurfaceHostTests {
    @Test func leoToSplitTreeDirectionMapsEachCase() {
        #expect(isLeft(leoSplitTreeDirection(for: .left)))
        #expect(isRight(leoSplitTreeDirection(for: .right)))
        #expect(isUp(leoSplitTreeDirection(for: .up)))
        #expect(isDown(leoSplitTreeDirection(for: .down)))
    }

    @Test func splitTreeToLeoDirectionMapsEachCase() {
        #expect(leoSplitDirection(for: .left) == .left)
        #expect(leoSplitDirection(for: .right) == .right)
        #expect(leoSplitDirection(for: .up) == .up)
        #expect(leoSplitDirection(for: .down) == .down)
    }

    private func isLeft(_ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) -> Bool {
        if case .left = direction { return true }
        return false
    }

    private func isRight(_ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) -> Bool {
        if case .right = direction { return true }
        return false
    }

    private func isUp(_ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) -> Bool {
        if case .up = direction { return true }
        return false
    }

    private func isDown(_ direction: SplitTree<Ghostty.SurfaceView>.NewDirection) -> Bool {
        if case .down = direction { return true }
        return false
    }
}
