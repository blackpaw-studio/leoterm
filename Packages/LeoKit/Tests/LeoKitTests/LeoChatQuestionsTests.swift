import Foundation
import Testing

@testable import LeoKit

struct LeoChatQuestionsTests {
    static let questionsInput = #"""
    {"type":"questions","questions":[
      {"id":"q1","header":"Library","question":"Which library?","multi":false,"allow_text":true,
       "options":[{"value":"Swift","label":"Swift","description":"Fast"},{"value":"Zig","label":"Zig"}]},
      {"id":"q2","header":"Scope","question":"Which scopes?","multi":true,"allow_text":true,
       "options":[{"value":"A","label":"A"},{"value":"B","label":"B"}]}
    ]}
    """#

    static func question(id: String = "q1", options: String = #"[{"value":"a","label":"a"}]"#) -> String {
        #"{"id":"\#(id)","header":"H","question":"Q \#(id)?","multi":false,"allow_text":true,"options":\#(options)}"#
    }

    static func input(_ questions: [String]) -> String {
        #"{"type":"questions","questions":[\#(questions.joined(separator: ","))]}"#
    }

    @Test func decodesAQuestionsAskWithItsQuestionsAndOptionDescriptions() throws {
        let input = try #require(try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: Self.questionsInput)).input)

        #expect(input.kind == .questions)
        #expect(input.questions.map(\.id) == ["q1", "q2"])
        #expect(input.questions[0].header == "Library")
        #expect(input.questions[0].question == "Which library?")
        #expect(input.questions[1].multi)
        #expect(input.questions[0].allowsText)
        #expect(input.questions[0].options[0].description == "Fast")
    }

    @Test func anOptionWithoutADescriptionHasNone() throws {
        let questions = try #require(try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: Self.questionsInput)).input).questions
        let buttons = try #require(try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: #"{"type":"buttons","options":\#(LeoChatDecodingTests.yesNo)}"#)).input)

        #expect(questions[0].options[1].description == nil)
        #expect(buttons.options.allSatisfy { $0.description == nil })
    }

    @Test func otherInputKindsCarryNoQuestions() throws {
        let buttons = try #require(try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: #"{"type":"buttons","options":\#(LeoChatDecodingTests.yesNo)}"#)).input)
        #expect(buttons.questions.isEmpty)
    }

    @Test(arguments: [
        LeoChatQuestionsTests.input([]),
        LeoChatQuestionsTests.input((1...5).map { LeoChatQuestionsTests.question(id: "q\($0)") }),
        LeoChatQuestionsTests.input([LeoChatQuestionsTests.question(id: "q1"), LeoChatQuestionsTests.question(id: "q1")]),
        LeoChatQuestionsTests.input([LeoChatQuestionsTests.question(id: "")]),
        LeoChatQuestionsTests.input([LeoChatQuestionsTests.question(options: "[]")]),
        LeoChatQuestionsTests.input([LeoChatQuestionsTests.question(options: #"[{"value":"a","label":"a"},{"value":"a","label":"a"}]"#)]),
        #"{"type":"questions"}"#,
    ])
    func anInvalidQuestionsInputFailsTheMessage(json: String) {
        #expect(throws: (any Error).self) { try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: json)) }
    }

    @Test func aQuestionsAskRoundTripsThroughItsOwnEncoding() throws {
        let input = try #require(try LeoChatDecodingTests.decode(LeoChatDecodingTests.ask(input: Self.questionsInput)).input)

        let decoded = try JSONDecoder().decode(LeoChatInput.self, from: JSONEncoder().encode(input))

        #expect(decoded == input)
        #expect(decoded.questions[0].options[0].description == "Fast")
    }

    @Test func aPageKeepsItsOtherMessagesWhenAnAskHasAnUnknownInputType() throws {
        let json = #"""
        {"messages":[
          \#(LeoChatDecodingTests.ask(input: #"{"type":"slider"}"#)),
          {"id":"01JT","agent":"zeus","direction":"out","kind":"text","text":"hi","ts":0}
        ],"has_more":false}
        """#
        let page = try JSONDecoder().decode(LeoChatPage.self, from: Data(json.utf8))

        #expect(page.messages.map(\.id) == ["01JT"])
    }
}
