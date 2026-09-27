import Testing
import Foundation
@testable import Ghostty

struct UpdateFeedTests {
    static let leoFeed = "https://github.com/blackpaw-studio/leoterm/releases/latest/download/appcast.xml"

    @Test(arguments: [Ghostty.AutoUpdateChannel.stable, .tip])
    func everyChannelUsesLeoFeed(channel: Ghostty.AutoUpdateChannel) {
        #expect(UpdateFeed.urlString(for: channel) == Self.leoFeed)
    }

    @Test func feedIsAValidHTTPSURL() throws {
        let url = try #require(URL(string: UpdateFeed.urlString(for: .stable)))
        #expect(url.scheme == "https")
    }
}
