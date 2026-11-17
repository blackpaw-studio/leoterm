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
}
