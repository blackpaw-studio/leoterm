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

    // MARK: Answers

    static func message(state: String, closedReason: String? = nil, answer: String? = nil) throws -> LeoChatMessage {
        let extras = [
            closedReason.map { #""closed_reason":"\#($0)""# }, answer.map { #""answer":\#($0)"# },
        ].compactMap { $0 }.map { "," + $0 }.joined()
        let json = #"{"id":"01JQ","agent":"zeus","direction":"out","kind":"ask","text":"q","state":"\#(state)","ts":0,"input":\#(questionsInput)\#(extras)}"#
        return try JSONDecoder().decode(LeoChatMessage.self, from: Data(json.utf8))
    }

    static let echo = #"{"values":[],"text":"","answers":{"q1":{"values":["Swift"],"text":""},"q2":{"values":[],"text":"because"}}}"#

    @Test func decodesTheAnswersEchoOfAnAnsweredCard() throws {
        let answer = try #require(try Self.message(state: "answered", answer: Self.echo).answer)

        #expect(answer.answers?["q1"] == .choice("Swift"))
        #expect(answer.answers?["q2"] == LeoChatAnswer(values: [], text: "because"))
    }

    @Test func anAnswerWithoutAnswersDecodesAsBefore() throws {
        let answer = try JSONDecoder().decode(LeoChatAnswer.self, from: Data(#"{"values":["yes"],"text":""}"#.utf8))
        #expect(answer.answers == nil)
    }

    @Test func anAnswersEchoRoundTripsThroughItsOwnEncoding() throws {
        let answer = try #require(try Self.message(state: "answered", answer: Self.echo).answer)
        #expect(try JSONDecoder().decode(LeoChatAnswer.self, from: JSONEncoder().encode(answer)) == answer)
    }

    @Test func aTextOnlyAnswerStillFailsToDecode() {
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LeoChatAnswer.self, from: Data(#"{"text":"x"}"#.utf8)) }
    }

    @Test func aTerminalAnswerHasNoAnswersAndSaysSo() throws {
        let terminal = try Self.message(state: "answered", answer: #"{"values":["terminal"],"text":""}"#)
        let echoed = try Self.message(state: "answered", answer: Self.echo)

        #expect(terminal.answer?.isFromTerminal == true)
        #expect(terminal.isAnsweredInTerminal)
        #expect(terminal.questionsCard == .inTerminal)
        #expect(echoed.answer?.isFromTerminal == false)
        #expect(!echoed.isAnsweredInTerminal)
        #expect(LeoChatAnswer(values: ["terminal"], answers: ["q1": .choice("Swift")]).isFromTerminal == false)
    }

    @Test func summaryLinesReadHeaderThenLabelsThenQuotedText() throws {
        let message = try Self.message(state: "answered", answer: #"{"values":[],"text":"","answers":{"q1":{"values":["Swift"],"text":""},"q2":{"values":["A","B"],"text":"docs too"}}}"#)
        let questions = try #require(message.input?.questions)

        #expect(message.answer?.summaryLines(for: questions) == ["Library: Swift", #"Scope: A, B, "docs too""#])
    }

    @Test func aQuestionMissingFromTheEchoReadsNone() throws {
        let message = try Self.message(state: "answered", answer: #"{"values":[],"text":"","answers":{"q1":{"values":["Swift"],"text":""}}}"#)
        let questions = try #require(message.input?.questions)

        #expect(message.answer?.summaryLines(for: questions) == ["Library: Swift", "Scope: None"])
    }

    @Test func aTextOnlyQuestionShowsItsQuotedText() throws {
        let message = try Self.message(state: "answered", answer: #"{"values":[],"text":"","answers":{"q1":{"values":[],"text":"Go"},"q2":{"values":["A"],"text":""}}}"#)
        let questions = try #require(message.input?.questions)

        #expect(message.answer?.summaryLines(for: questions) == [#"Library: "Go""#, "Scope: A"])
    }

    @Test func aDismissedCardReadsAsInTerminalATimeoutAsTimedOut() throws {
        #expect(try Self.message(state: "open").questionsCard == .open)
        #expect(try Self.message(state: "expired", closedReason: "dismissed").questionsCard == .inTerminal)
        #expect(try Self.message(state: "expired", closedReason: "timeout").questionsCard == .timedOut)
        #expect(try Self.message(state: "expired", closedReason: "withdrawn").questionsCard == .expired)
        #expect(try Self.message(state: "expired", closedReason: "agent_gone").questionsCard == .expired)
        #expect(try Self.message(state: "expired").questionsCard == .expired)
    }

    @Test func anAnsweredCardCarriesItsSummaryLines() throws {
        let message = try Self.message(state: "answered", answer: Self.echo)
        #expect(message.questionsCard == .answered(["Library: Swift", #"Scope: "because""#]))
    }

    @Test func onlyAQuestionsAskHasACardState() throws {
        let buttons = try LeoChatDecodingTests.decode(LeoChatDecodingTests.askJSON)
        #expect(buttons.questionsCard == nil)
    }

    @Test func theClosedReasonSurvivesEncodingAndAnswering() throws {
        let message = try Self.message(state: "expired", closedReason: "timeout")
        let decoded = try JSONDecoder().decode(LeoChatMessage.self, from: JSONEncoder().encode(message))

        #expect(decoded.closedReason == "timeout")
        #expect(message.answered(.choice("x")).closedReason == "timeout")
    }
}
