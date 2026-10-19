#if DEBUG
import ComposableArchitecture
import LeoFeatures
import LeoKit
import UIKit

/// A chat thread of fixture questions cards for UI tests and screenshots
/// (`-questionsCardFixture <state>`), run with a scripted chat client so no
/// daemon is needed. `all` shows every state in one long thread, with filler
/// messages so cards scroll off and their cells get reused.
enum ChatQuestionsFixture {
    static let launchKey = "questionsCardFixture"

    /// Which fixture a launch asked for, if any.
    static var requested: String? {
        guard ProcessInfo.processInfo.arguments.contains("-\(launchKey)") else { return nil }
        return UserDefaults.standard.string(forKey: launchKey)
    }

    private static let longOption = "Both, with the public API unchanged and callers migrated later"
    private static let terminalAnswer = LeoChatAnswer(values: [LeoChatMessage.terminalAnswerValue])

    static let agent = "zeus"
    static let daemon = PairedDaemon(
        id: "fixture-daemon", name: "Fixture", baseURL: URL(string: "https://fixture.invalid")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )

    /// Long enough to need scrolling (the `all` and `long` fixtures).
    static let longQuestions = [
        LeoChatQuestion(id: "q1", header: "Library", question: "Which library should the parser use?", options: [
            LeoChatOption(value: "Swift", label: "Swift", description: "Fast, and ships with the toolchain"),
            LeoChatOption(value: "Zig", label: "Zig", description: "Small binaries, manual memory"),
            LeoChatOption(value: Self.longOption, label: Self.longOption)
        ]),
        LeoChatQuestion(id: "q2", header: "Scope", question: "Which parts should it cover?", multi: true, options: [
            LeoChatOption(value: "Lexer", label: "Lexer", description: "Splits input into tokens"),
            LeoChatOption(value: "Parser", label: "Parser"),
            LeoChatOption(value: "Formatter", label: "Formatter", description: "Prints the tree back out")
        ])
    ]

    /// Two short questions: a whole card fits one screen, for the state captures.
    static let questions = [
        LeoChatQuestion(id: "q1", header: "Library", question: "Which library should the parser use?", options: [
            LeoChatOption(value: "Swift", label: "Swift", description: "Fast, and ships with the toolchain"),
            LeoChatOption(value: "Zig", label: "Zig", description: "Small binaries, manual memory")
        ]),
        LeoChatQuestion(id: "q2", header: "Scope", question: "Which parts should it cover?", multi: true, options: [
            LeoChatOption(value: "Lexer", label: "Lexer", description: "Splits input into tokens"),
            LeoChatOption(value: "Parser", label: "Parser")
        ])
    ]

    /// Every state, in thread order.
    static let stateNames = [
        "open", "partial", "filled", "refused", "sending", "answered", "terminal", "dismissed", "timedout"
    ]

    private static let baseTime = Date().addingTimeInterval(-3_600)

    private static func card(
        _ name: String, long: Bool = false, state: String = "open", answer: LeoChatAnswer? = nil,
        closedReason: String? = nil
    ) -> LeoChatMessage {
        LeoChatMessage(
            id: "card-\(name)", agent: agent, direction: .outbound, kind: .ask, text: "", state: state, answer: answer,
            ts: baseTime.addingTimeInterval(Double(stateNames.firstIndex(of: name) ?? 0) * 60),
            input: try? LeoChatInput(questions: long ? longQuestions : questions), closedReason: closedReason
        )
    }

    static let echo = LeoChatAnswer(answers: [
        "q1": .choice("Swift"),
        "q2": LeoChatAnswer(values: ["Lexer", "Parser"], text: "and the CLI")
    ])

    static func messages(for name: String) -> [LeoChatMessage] {
        if name == "long" { return [card("long", long: true)] }
        let isAll = name == "all"
        let all: [String: LeoChatMessage] = [
            "open": card("open", long: isAll),
            "partial": card("partial", long: isAll),
            "filled": card("filled", long: isAll),
            "refused": card("refused", long: isAll),
            "sending": card("sending", long: isAll),
            "answered": card("answered", long: isAll, state: "answered", answer: echo),
            "terminal": card("terminal", long: isAll, state: "answered", answer: terminalAnswer),
            "dismissed": card("dismissed", long: isAll, state: "expired", closedReason: "dismissed"),
            "timedout": card("timedout", long: isAll, state: "expired", closedReason: "timeout")
        ]
        guard isAll else { return all[name].map { [$0] } ?? [] }
        let fillers = (0..<14).map { index in
            LeoChatMessage(
                id: "filler-\(index)", agent: agent, direction: .outbound, kind: .text,
                text: "Working on step \(index + 1)…",
                ts: baseTime.addingTimeInterval(Double(stateNames.count + index) * 60)
            )
        }
        return stateNames.compactMap { all[$0] } + fillers
    }

    /// The drafts, in-flight set and refused-answer notes the states need.
    private static func initialState(for name: String) -> ChatThread.State {
        var state = ChatThread.State(daemon: daemon, agent: agent)
        let set = name == "all" ? longQuestions : questions
        let empty = LeoChatQuestionsDraft(questions: set)
        let partial = empty.choosing("Swift", question: "q1")
        let filled = partial
            .choosing("Lexer", question: "q2").choosing("Parser", question: "q2")
            .withText("and the CLI", question: "q2")
        for target in [name == "all" ? stateNames : [name]].flatMap({ $0 }) {
            switch target {
            case "partial": state.questionsDrafts["card-partial"] = partial
            case "filled": state.questionsDrafts["card-filled"] = filled
            case "refused":
                state.questionsDrafts["card-refused"] = filled
                state.questionsErrors["card-refused"] = "invalid: q2 text is over 4000 characters"
            case "sending":
                state.questionsDrafts["card-sending"] = filled
                state.answering = ["card-sending"]
            default: break
            }
        }
        return state
    }

    /// A thread store over a scripted client: it serves the fixture page,
    /// settles a submit with the echoed answers and a dismiss as dismissed.
    @MainActor
    static func store(for name: String) -> StoreOf<ChatThread> {
        let page = LeoChatPage(messages: messages(for: name), hasMore: false)
        return Store(initialState: initialState(for: name)) {
            ChatThread()
        } withDependencies: {
            $0.secrets.load = { _ in DaemonSecrets(token: "fixture") }
            $0.chatClient.messages = { _, _, _ in page }
            $0.chatClient.markRead = { _, _, _ in }
            $0.chatClient.answerQuestions = { _, _, id, answers in
                guard let sent = page.messages.first(where: { $0.id == id }) else { return nil }
                return sent.answered(LeoChatAnswer(answers: answers))
            }
            $0.chatClient.dismiss = { _, _, id in
                guard let sent = page.messages.first(where: { $0.id == id }) else { return nil }
                return LeoChatMessage(
                    id: sent.id, agent: sent.agent, direction: sent.direction, kind: sent.kind, text: sent.text,
                    state: "expired",
                    ts: sent.ts, input: sent.input, closedReason: "dismissed"
                )
            }
        }
    }

    @MainActor
    static func rootViewController(for name: String) -> UIViewController {
        UINavigationController(rootViewController: ChatThreadViewController(store: store(for: name)))
    }
}
#endif
