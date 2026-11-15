import LeoKit
import Testing
import UIKit

@testable import Leo
@testable import LeoFeatures

@MainActor
struct TaskPanelViewTests {
    private static let ref = AgentRef(daemonID: "d", name: "zeus")

    private func panel() -> (TaskPanelView, UIView) {
        let host = UIView(frame: CGRect(x: 0, y: 0, width: 402, height: 800))
        let panel = TaskPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.topAnchor.constraint(equalTo: host.topAnchor, constant: 100),
            panel.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -12),
            panel.widthAnchor.constraint(equalToConstant: 320),
        ])
        let task = LeoAgentTask(
            id: "a", title: "Build", mode: .determinate, percent: 40, status: nil,
            state: .running, stale: false, startedAt: Date(), updatedAt: nil, endedAt: nil, revision: 1
        )
        let row = TaskPanelRow(ref: Self.ref, displayName: "zeus", emoji: nil, task: task, etaAt: nil)
        panel.render(header: "Tasks 1 · 40%", rows: [row], isCollapsed: false, now: Date())
        host.layoutIfNeeded()
        return (panel, host)
    }

    private func header(of panel: TaskPanelView) -> UIButton? {
        panel.descendants.compactMap { $0 as? UIButton }.first { $0.accessibilityIdentifier == "tasks.panel.header" }
    }

    @Test func aTouchOnTheHeaderReachesItsButtonAndToggles() throws {
        let (panel, host) = panel()
        let button = try #require(header(of: panel))
        var toggles = 0
        panel.onToggle = { toggles += 1 }

        let point = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
        let hit = host.hitTest(point, with: nil)
        #expect(hit === button || hit?.isDescendant(of: button) == true)

        button.sendActions(for: .touchUpInside)
        #expect(toggles == 1)
    }

    @Test func theWholeHeaderRowIsTappable() throws {
        let (panel, host) = panel()
        let button = try #require(header(of: panel))
        let frame = button.convert(button.bounds, to: host)
        // Far right of the card, past the title: still the button, not the blur behind it.
        let hit = host.hitTest(CGPoint(x: frame.maxX - 4, y: frame.midY), with: nil)
        #expect(hit === button || hit?.isDescendant(of: button) == true)
    }
}

private extension UIView {
    var descendants: [UIView] { subviews + subviews.flatMap(\.descendants) }
}
