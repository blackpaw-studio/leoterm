import Testing

@testable import Ghostty

struct LeoDrawerPathTests {
    private let home = "/Users/evan"

    @Test
    func aHomePathIsAbbreviatedLikeTheStatusPlugin() {
        #expect(LeoDrawerPath.summary(pwd: nil, workspace: "/Users/evan/.leo/agents/leoterm", home: home) == "~/.l/a/leoterm")
    }

    @Test
    func theShellsReportedDirectoryBeatsTheWorkspace() {
        let summary = LeoDrawerPath.summary(pwd: "/Users/evan/src/app", workspace: "/Users/evan/.leo/agents/x", home: home)
        #expect(summary == "~/s/app")
    }

    @Test
    func anOsc7FileUrlIsReducedToItsPath() {
        #expect(LeoDrawerPath.summary(pwd: "file://dionysus.local/Users/evan/src/app", workspace: nil, home: home) == "~/s/app")
        #expect(LeoDrawerPath.summary(pwd: "file:///Users/evan/src%20x/app", workspace: nil, home: home) == "~/s/app")
    }

    @Test
    func anEmptyOrUnparseablePwdFallsBackToTheWorkspace() {
        #expect(LeoDrawerPath.summary(pwd: "", workspace: "/srv/app", home: home) == "/s/app")
        #expect(LeoDrawerPath.summary(pwd: "file://", workspace: "/srv/app", home: home) == "/s/app")
    }

    @Test
    func nothingKnownGivesNoSummary() {
        #expect(LeoDrawerPath.summary(pwd: nil, workspace: nil, home: home) == nil)
        #expect(LeoDrawerPath.summary(pwd: "", workspace: "", home: home) == nil)
    }

    @Test
    func rootAndSingleComponentsStayWhole() {
        #expect(LeoDrawerPath.summary(pwd: "/", workspace: nil, home: home) == "/")
        #expect(LeoDrawerPath.summary(pwd: "/srv", workspace: nil, home: home) == "/srv")
        #expect(LeoDrawerPath.summary(pwd: "/Users/evan", workspace: nil, home: home) == "~")
    }

    @Test
    func aRemotePathWithNoHomeIsShortenedWithoutTilde() {
        #expect(LeoDrawerPath.summary(pwd: nil, workspace: "/home/dev/.leo/agents/leoterm", home: nil) == "/h/d/.l/a/leoterm")
    }

    @Test
    func homeOnlyMatchesAWholeComponent() {
        #expect(LeoDrawerPath.summary(pwd: "/Users/evanx/proj", workspace: nil, home: home) == "/U/e/proj")
    }
}
