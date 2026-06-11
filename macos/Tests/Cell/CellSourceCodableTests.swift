import Testing
import Foundation
@testable import Ghostty

struct CellSourceCodableTests {
    @Test func ptyRoundTrips() throws {
        let data = try JSONEncoder().encode(CellSource.pty)
        #expect(try JSONDecoder().decode(CellSource.self, from: data) == .pty)
    }

    @Test func agentRoundTrips() throws {
        let source = CellSource.agent(name: "olympus")
        let data = try JSONEncoder().encode(source)
        #expect(try JSONDecoder().decode(CellSource.self, from: data) == source)
    }

    @Test func agentEncodesStableShape() throws {
        let data = try JSONEncoder().encode(CellSource.agent(name: "olympus"))
        let json = String(data: data, encoding: .utf8)!
        #expect(json.contains("\"agent\""))
        #expect(json.contains("\"olympus\""))
    }
}
