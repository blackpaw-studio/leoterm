import Foundation
import Testing

@testable import LeoKit

struct LeoBrowserClosedTabsTests {
    private func url(_ n: Int) -> URL { URL(string: "http://localhost:\(n)/")! }

    @Test func reopensMostRecentlyClosedFirst() {
        var closed = LeoBrowserClosedTabs()
        closed.record(.init(url: url(1), index: 0, userAgent: nil))
        closed.record(.init(url: url(2), index: 3, userAgent: "UA"))
        #expect(closed.popLast() == .init(url: url(2), index: 3, userAgent: "UA"))
        #expect(closed.popLast() == .init(url: url(1), index: 0, userAgent: nil))
        #expect(closed.popLast() == nil)
        #expect(closed.isEmpty)
    }

    @Test func blankAndURLlessTabsAreNotRecorded() {
        var closed = LeoBrowserClosedTabs()
        closed.record(.init(url: nil, index: 0, userAgent: nil))
        closed.record(.init(url: URL(string: "about:blank")!, index: 1, userAgent: nil))
        #expect(closed.isEmpty)
    }

    @Test func keepsOnlyTheLatestTwenty() {
        var closed = LeoBrowserClosedTabs()
        for n in 1...25 { closed.record(.init(url: url(n), index: 0, userAgent: nil)) }
        #expect(closed.count == LeoBrowserClosedTabs.capacity)
        #expect(closed.popLast()?.url == url(25))
        var last: URL?
        while let tab = closed.popLast() { last = tab.url }
        #expect(last == url(6))
    }
}
