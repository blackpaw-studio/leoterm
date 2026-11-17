import Foundation
import Testing

@testable import LeoKit

struct LeoFileNameTests {
    @Test(arguments: [
        ("a.txt", 2, "a 2.txt"),
        ("report.tar.gz", 3, "report.tar 3.gz"),
        ("Makefile", 2, "Makefile 2"),
        (".env", 2, ".env 2"),
    ])
    func numberedInsertsBeforeExtension(name: String, number: Int, expected: String) {
        #expect(LeoFileName.numbered(name, number) == expected)
    }

    @Test func stagingPathIsAHiddenSiblingThatIsStagingNamed() {
        let staging = LeoFileName.stagingPath(for: "/ws/downloads/x.pdf")
        #expect((staging as NSString).deletingLastPathComponent == "/ws/downloads")
        let name = (staging as NSString).lastPathComponent
        #expect(name.wholeMatch(of: #/\.x\.pdf\.leo-[0-9a-f]{32}\.tmp/#) != nil)
        #expect(LeoFileName.isStagingName(name))
        #expect(LeoFileName.stagingPath(for: "/ws/x.pdf") != LeoFileName.stagingPath(for: "/ws/x.pdf"))
    }

    @Test func aLongNameStillGivesAStagingNameWithinNameMax() {
        let name = (LeoFileName.stagingPath(for: "/ws/" + String(repeating: "é", count: 200)) as NSString).lastPathComponent
        #expect(name.utf8.count <= 255)
        #expect(LeoFileName.isStagingName(name))
    }

    @Test(arguments: [
        "x.pdf", ".x.pdf", ".x.pdf.leo-1234.tmp", "x.pdf.leo-0123456789abcdef0123456789abcdef.tmp",
        ".x.pdf.leo-0123456789ABCDEF0123456789ABCDEF.tmp", "..leo-0123456789abcdef0123456789abcdef.tmp",
        ".x.pdf.leo-0123456789abcdef0123456789abcdef.tmp/", ".x/y.leo-0123456789abcdef0123456789abcdef.tmp",
    ])
    func nonStagingNamesAreRefused(name: String) {
        #expect(!LeoFileName.isStagingName(name))
    }
}
