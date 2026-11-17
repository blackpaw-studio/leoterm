#if DEBUG
import ComposableArchitecture
import Foundation
import LeoFeatures
import LeoKit
import UIKit

/// DEBUG builds only: an agent's browser on iPhone with no daemon (B-305),
/// for screenshots. `LEO_BROWSER_FIXTURE=<scenario>` pairs a fake
/// "Dionysus" advertising `client_tools`, opens agent zeus's browser, loads
/// a sign-in page, and plays the scenario's agent calls through the real
/// client-tools session and executor (only the daemon is fake):
///
/// - `handoff` (default): zeus snapshots the page, types an email, then
///   asks for a handoff, so the banner shows.
/// - `localhost`: the address bar is given `localhost:5173`, so the pane
///   says why it can't load.
/// - `address`: the address bar is given text that isn't an address, so
///   the pane shows its headingless bar.
/// - `dialog`: the page asks `confirm()`, so the dialog bar shows.
/// - `control`: the user takes control (Give Back shows).
enum BrowserFixture {
    static let environmentKey = "LEO_BROWSER_FIXTURE"
    static var isRequested: Bool { ProcessInfo.processInfo.environment[environmentKey] != nil }
    private static var scenario: String { ProcessInfo.processInfo.environment[environmentKey].flatMap { $0.isEmpty ? nil : $0 } ?? "handoff" }

    private static let daemon = PairedDaemon(
        id: "fixture-browser", name: "Dionysus", baseURL: URL(string: "https://dionysus.lan")!, urls: [],
        deviceID: "fixture-device", pairedAt: Date(timeIntervalSince1970: 0)
    )
    private static let zeus = AgentRef(daemonID: daemon.id, name: "zeus")
    @MainActor private static let provider = FixtureProvider()
    @MainActor private static let runtime = AgentBrowserApp.runtime { _ in provider }

    private static let page = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Sign in · Example Shop</title>
    <style>body{font:17px -apple-system,sans-serif;margin:0;background:#f6f6f8;color:#111}header{background:#1f3b73;color:#fff;padding:18px 20px;font-weight:600}
    main{padding:24px 20px}label{display:block;font-size:14px;color:#555;margin:16px 0 6px}input{width:100%;box-sizing:border-box;font-size:17px;padding:12px;border:1px solid #ccc;border-radius:10px;background:#fff}
    button{margin-top:24px;width:100%;font-size:17px;padding:14px;border:0;border-radius:12px;background:#1f3b73;color:#fff;font-weight:600}p{color:#666;font-size:14px}</style></head>
    <body><header>Example Shop</header><main><h2>Sign in</h2><form onsubmit="return false"><label for="email">Email</label><input id="email" type="email" autocomplete="off">
    <label for="password">Password</label><input id="password" type="password"><button>Continue</button></form>
    <p>We’ll send a one-time code to the phone on your account.</p></main></body></html>
    """

    static func prepare(_ values: inout DependencyValues) {
        values.pairedDaemons.load = { [daemon] in [daemon] }
        values.pairedDaemons.save = { _ in }
        values.secrets.load = { _ in DaemonSecrets(token: "fixture") }
        values.daemonClient.fetchState = { _ in
            LeoObservedState(agents: [LeoObservedAgent(
                name: "zeus", status: .running, activity: .working, currentAction: nil, lastActivityAt: nil,
                attention: nil, startedAt: nil, template: "assistant", harness: "claude",
                appearance: LeoAgentAppearance(emoji: "⚡️", color: nil, emojiSource: .manual, colorSource: .manual), tasks: []
            )])
        }
        values.daemonClient.events = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.hello(seq: 1, at: nil, version: "0.60.0", serverTime: nil, features: ["client_tools"]))
            }
        }
        values.chatClient.threads = { _ in [LeoChatThread(agent: "zeus")] }
        values.chatClient.messages = { _, _, _ in LeoChatPage(messages: [], hasMore: false) }
        values.chatClient.markRead = { _, _, _ in }
        // The system's notification prompt would cover the page.
        values.pushClient.authorization = { .denied }
        values.clientTools = MainActor.assumeIsolated { ClientToolsClient.live(runtime: runtime) }
    }

    /// Opens zeus's browser once the fleet has it, loads the page, then plays the scenario.
    @MainActor static func open(_ store: StoreOf<AppFeature>) {
        store.send(.tabSelected(.agents))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            store.send(.notificationOpened(zeus))
            try? await Task.sleep(for: .seconds(1))
            store.send(.detail(.browserButtonTapped))
            try? await Task.sleep(for: .seconds(1))
            guard let browser = runtime.browser(for: zeus) as? LeoIOSAgentBrowser else { return }
            browser.activeWebView?.loadHTMLString(page, baseURL: URL(string: "https://shop.example.com/signin"))
            try? await Task.sleep(for: .seconds(1.5))
            await play(browser)
        }
    }

    @MainActor private static func play(_ browser: LeoIOSAgentBrowser) async {
        switch scenario {
        case "localhost":
            browser.navigate(to: "localhost:5173")
        case "address":
            browser.navigate(to: "not an address")
        case "dialog":
            _ = try? await browser.activeWebView?.evaluateJavaScript("setTimeout(() => confirm('Discard the items in your cart?'), 100); 0")
        case "control":
            browser.control.send(.pill)
        default:
            await typeEmail()
            _ = await provider.call("browser_handoff", ["message": .string("Enter the 6-digit code Example Shop sent to your phone, then tap Done.")], wait: false)
        }
    }

    /// zeus reads the page and fills in the email field, as an agent would.
    @MainActor private static func typeEmail() async {
        let log = LeoLog.logger(category: "fixture")
        let outcome = await provider.call("browser_snapshot", [:])
        guard case .success(let content)? = outcome, case .text(let snapshot)? = content.first else {
            return log.error("Browser fixture snapshot failed: \(String(describing: outcome), privacy: .public)")
        }
        guard let line = snapshot.split(separator: "\n").first(where: { $0.contains("textbox \"Email\"") }),
              let range = line.range(of: #"s\d+e\d+"#, options: .regularExpression) else {
            return log.error("Browser fixture found no Email field in: \(snapshot, privacy: .public)")
        }
        let typed = await provider.call("browser_type", ["ref": .string(String(line[range])), "text": .string("evan@example.com")])
        if case .failure? = typed { log.error("Browser fixture typing failed: \(String(describing: typed), privacy: .public)") }
    }
}

/// A daemon that only ever has zeus's calls: each `call` is delivered as a
/// request already owned by this client, and its result comes back here.
@MainActor private final class FixtureProvider: LeoClientToolsProviding {
    private static let clientID = "fixture-iphone"
    private var continuation: AsyncStream<LeoClientToolsEvent>.Continuation?
    private var requests: [String: LeoClientToolRequest] = [:]
    private var waiting: [String: CheckedContinuation<LeoClientToolOutcome?, Never>] = [:]
    private var nextID = 1

    @MainActor func events() async -> AsyncStream<LeoClientToolsEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: LeoClientToolsEvent.self)
        self.continuation = continuation
        continuation.yield(.hello(clientID: Self.clientID))
        return stream
    }

    @MainActor func register(group: String, tools: [LeoClientToolDefinition]) async throws -> Int { 1 }

    @MainActor func claim(_ requestID: String) async throws -> LeoClientToolRequest {
        guard let request = requests[requestID] else { throw LeoClientToolsError.unknownRequest(message: "unknown") }
        return request
    }

    @MainActor func postResult(_ requestID: String, _ outcome: LeoClientToolOutcome) async throws {
        waiting.removeValue(forKey: requestID)?.resume(returning: outcome)
    }

    @MainActor func pending() async throws -> [LeoClientToolPending] { [] }

    /// Delivers a `tool` call from zeus and, with `wait`, returns its outcome.
    func call(_ tool: String, _ args: [String: LeoJSONValue], wait: Bool = true) async -> LeoClientToolOutcome? {
        let id = "fixture_\(nextID)"
        nextID += 1
        let request = LeoClientToolRequest(
            id: id, agent: "zeus", group: "browser", tool: tool, args: .object(args), owner: Self.clientID, timeoutSeconds: 300
        )
        requests[id] = request
        guard wait else {
            continuation?.yield(.request(request))
            return nil
        }
        return await withCheckedContinuation { waiter in
            waiting[id] = waiter
            continuation?.yield(.request(request))
        }
    }
}
#endif
