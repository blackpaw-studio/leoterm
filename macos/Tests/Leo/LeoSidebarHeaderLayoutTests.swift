import AppKit
import SwiftUI
import Testing

@testable import Ghostty

/// B-064: the sidebar's "Agents" title and its New Agent button sat flush
/// against the window's titlebar. These host the real `LeoSidebarView` as
/// the content view of a real titled window (shown, never made key) and read
/// where the header lands through `leoSidebarHeaderFrameSink`, measured from
/// the top of the sidebar itself -- which fills the content area, so its top
/// is the titlebar's bottom edge.
@MainActor @Suite(.serialized)
struct LeoSidebarHeaderLayoutTests {
    private static let defaultWidth: CGFloat = 320
    private static let minimumSidebarWidth = LeoSidebarSplitMetrics.minimumWidth
    private static let height: CGFloat = 480

    @Test func headerTitleClearsTheTitlebarWithStandardSpacing() async throws {
        let (window, frames) = makeWindow(width: Self.defaultWidth)
        defer { window.close() }
        let title = try #require(await frames.settled(.title), "\(frames)")

        #expect(title.minY >= 8, "the Agents title sits \(title.minY) pt below the titlebar")
    }

    @Test func newAgentButtonClearsTheTitlebarWithStandardSpacing() async throws {
        let (window, frames) = makeWindow(width: Self.defaultWidth)
        defer { window.close() }
        let button = try #require(await frames.settled(.accessory), "\(frames)")

        #expect(button.minY >= 6, "the New Agent button sits \(button.minY) pt below the titlebar")
    }

    @Test(arguments: [defaultWidth, minimumSidebarWidth])
    func headerTitleAndButtonShareARowWithAGapBetween(_ width: CGFloat) async throws {
        let (window, frames) = makeWindow(width: width)
        defer { window.close() }
        let title = try #require(await frames.settled(.title), "\(frames)")
        let button = try #require(await frames.settled(.accessory), "\(frames)")

        #expect(abs(title.midY - button.midY) <= 1, "title \(title) and button \(button) share a row")
        #expect(button.minX - title.maxX >= 8, "title \(title) and button \(button) keep a gap")
        #expect(button.maxX <= width, "the button \(button) stays inside the \(width) pt sidebar")
    }

    // MARK: - Harness

    private func makeWindow(width: CGFloat) -> (NSWindow, HeaderFrames) {
        let agents = (0 ..< 2).map {
            LeoAgentRow(host: .local, name: "agent-\($0)", template: nil, status: .running, activity: .idle, actionDetail: nil)
        }
        let model = LeoSidebarModel(snapshot: LeoSidebarSnapshot(rows: agents, connectivity: .connected, generation: 1))
        let actions = LeoAgentActions(
            daemon: HeaderLayoutTestDaemon(), cli: LeoCLI(), model: model, hostSelection: .isolatedForTesting(), refresh: {}
        )
        let frames = HeaderFrames(contentSize: CGSize(width: width, height: Self.height))
        let window = NSWindow(
            contentRect: NSRect(x: 120, y: 120, width: width, height: Self.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(
            rootView: LeoSidebarView(model: model, windowID: LeoWindowID(), actions: actions, terminals: LeoWindowTerminals())
                .environment(\.leoSidebarHeaderFrameSink) { part, frame in frames.record(part, frame) }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frames.recordSidebar($0) }
        )
        window.orderFront(nil)
        return (window, frames)
    }
}

/// The latest frame reported for each header part, relative to the
/// sidebar's own top-left corner (global space also counts the titlebar).
@MainActor
private final class HeaderFrames: CustomStringConvertible {
    private let contentSize: CGSize
    private var sidebar: CGRect?
    private var frames: [LeoSidebarHeaderPart: CGRect] = [:]

    init(contentSize: CGSize) {
        self.contentSize = contentSize
    }

    var description: String {
        "sidebar \(sidebar.map { "\($0)" } ?? "unreported") in a \(contentSize) content area; parts \(frames)"
    }

    func record(_ part: LeoSidebarHeaderPart, _ frame: CGRect) {
        frames[part] = frame
    }

    func recordSidebar(_ frame: CGRect) {
        sidebar = frame
    }

    /// `part`'s frame once layout has sized it, the sidebar fills the
    /// content area, and both have held still for a few polls; nil if that
    /// never happens.
    func settled(_ part: LeoSidebarHeaderPart, timeout: Duration = .seconds(10)) async -> CGRect? {
        let deadline = ContinuousClock.now + timeout
        var last: CGRect?
        var stablePolls = 0
        while ContinuousClock.now < deadline {
            let current = relativeFrame(of: part)
            stablePolls = (current != nil && current == last) ? stablePolls + 1 : 0
            if stablePolls >= 3 { return current }
            last = current
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func relativeFrame(of part: LeoSidebarHeaderPart) -> CGRect? {
        guard let sidebar, sidebar.size == contentSize, let frame = frames[part], !frame.isEmpty else { return nil }
        return frame.offsetBy(dx: -sidebar.minX, dy: -sidebar.minY)
    }
}

private struct HeaderLayoutTestDaemon: LeoDaemonClient {
    func listAgents() async throws -> [LeoAgent] { [] }
    func spawn(_ request: LeoSpawnRequest) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func start(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func stop(_ name: String, wakeOnMessage: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func restart(_ name: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func reset(_ name: String) async throws { throw LeoDaemonError.transport("unused") }
    func setTemplate(_ name: String, template: String) async throws { throw LeoDaemonError.transport("unused") }
    func rename(_ name: String, newName: String) async throws -> LeoAgent { throw LeoDaemonError.transport("unused") }
    func delete(_ name: String, force: Bool?, deleteBranch: Bool?) async throws { throw LeoDaemonError.transport("unused") }
    func deletePlan(_ name: String) async throws -> LeoDeletePlan { throw LeoDaemonError.transport("unused") }
    func logs(_ name: String, lines: Int?) async throws -> String { throw LeoDaemonError.transport("unused") }
}
