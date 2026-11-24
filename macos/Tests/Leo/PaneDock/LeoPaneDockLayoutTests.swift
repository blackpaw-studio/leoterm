import Testing

@testable import Ghostty

/// B-439: Browser and Files each dock on the right or below the terminal.
/// Panes on one edge share a tab group; Files brings its outline column.
struct LeoPaneDockLayoutTests {
    @Test func eachPaneDefaultsToTheRightEdge() {
        let layout = LeoPaneDockLayout()

        #expect(layout.edge(of: .browser) == .right)
        #expect(layout.edge(of: .files) == .right)
    }

    @Test func panesOnDifferentEdgesFormTwoGroups() {
        let layout = LeoPaneDockLayout().moving(.browser, to: .below)

        let groups = layout.groups(open: [.browser, .files])

        #expect(groups == [LeoDockGroup(edge: .right, panes: [.files]), LeoDockGroup(edge: .below, panes: [.browser])])
    }

    /// Today's strip: the Browser item leads, then the files.
    @Test func panesOnTheSameEdgeShareOneTabGroup() {
        for edge in LeoDockEdge.allCases {
            let layout = LeoPaneDockLayout().moving(.browser, to: edge).moving(.files, to: edge)

            #expect(layout.groups(open: [.files, .browser]) == [LeoDockGroup(edge: edge, panes: [.browser, .files])])
        }
    }

    @Test func onlyTheFilesGroupHasTheOutlineColumn() {
        let layout = LeoPaneDockLayout().moving(.files, to: .below)

        let groups = layout.groups(open: [.browser, .files])

        #expect(groups.first { $0.edge == .below }?.hasOutline == true)
        #expect(groups.first { $0.edge == .right }?.hasOutline == false)
    }

    @Test func aClosedPaneLeavesItsEdgeEmpty() {
        let layout = LeoPaneDockLayout().moving(.browser, to: .below)

        #expect(layout.groups(open: [.files]) == [LeoDockGroup(edge: .right, panes: [.files])])
        #expect(layout.groups(open: [.browser]) == [LeoDockGroup(edge: .below, panes: [.browser])])
        #expect(layout.groups(open: []).isEmpty)
    }

    /// A dock keeps 200 pt however small it's asked to be, and otherwise
    /// leaves the terminal its floor.
    @Test(arguments: [
        // (asked, available, expected)
        (50.0, 1_000.0, 200.0),
        (400.0, 1_000.0, 400.0),
        (900.0, 1_000.0, 1_000.0 - LeoPaneDockMetrics.terminalFloor),
        (500.0, 250.0, 200.0),
    ])
    func dockSizeNeverGoesBelowTwoHundredPoints(asked: Double, available: Double, expected: Double) {
        let size = LeoPaneDockMetrics.clampedSize(CGFloat(asked), available: CGFloat(available))

        #expect(size == CGFloat(expected))
        #expect(size >= 200)
    }
}
