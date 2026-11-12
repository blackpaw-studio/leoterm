import Foundation
import Testing

@testable import LeoKit

struct LeoPluginJSRuntimeTests {
    private let agent = LeoPluginAgentRef(machine: "local", name: "alfred")
    private var viewSlot: LeoPluginSlotID { .view(viewID: "pr", agent: agent) }

    /// Collects what the runtime sends out, in order.
    private final class Sink {
        var requests: [LeoPluginHostRequest] = []
        var logs: [String] { requests.compactMap { if case .log(_, let m) = $0 { m } else { nil } } }
        var errors: [String] { requests.compactMap { if case .handlerError(_, let m) = $0 { m } else { nil } } }
    }

    private func makeRuntime(_ source: String) throws -> (LeoPluginJSRuntime, Sink) {
        let sink = Sink()
        let runtime = try LeoPluginJSRuntime(send: { sink.requests.append($0) })
        try runtime.load(source: source)
        return (runtime, sink)
    }

    // MARK: Sandbox surface

    @Test func exposesNoForbiddenGlobals() throws {
        let (_, sink) = try makeRuntime("""
        leo.log("info", [typeof fetch, typeof XMLHttpRequest, typeof require, typeof process,
                         typeof module, typeof WebSocket, typeof importScripts,
                         typeof setTimeout, typeof setInterval].join(","));
        """)
        #expect(sink.logs == ["undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined,undefined"])
    }

    @Test func leoIsTheOnlyBridgeAndIsFrozen() throws {
        let (_, sink) = try makeRuntime("""
        const keys = Object.keys(leo).sort().join(",");
        leo.log("info", keys);
        leo.sendToAgent = () => 1;          // frozen: silently ignored
        leo.log("info", String(typeof leo.sendToAgent) + "," + String(typeof leo.spawnAgent));
        """)
        #expect(sink.logs == [
            "after,agents,fetch,log,on,render,secrets,timer",
            "undefined,undefined",
        ])
    }

    @Test func noGlobalPostHookLeaks() throws {
        let (_, sink) = try makeRuntime("""
        const names = Object.getOwnPropertyNames(globalThis).filter(n => /post|native|bridge|__/i.test(n));
        leo.log("info", names.join(","));
        """)
        #expect(sink.logs == [""])
    }

    @Test func pluginCodeCannotCallSendOrSpawnDirectly() throws {
        // Even forging the request shape has nowhere to go: there is no hook.
        let (_, sink) = try makeRuntime("""
        let r = [];
        for (const f of ["sendToAgent", "spawnAgent"]) {
          try { leo[f]({}); r.push("callable"); } catch (e) { r.push("absent"); }
        }
        leo.log("info", r.join(","));
        """)
        #expect(sink.logs == ["absent,absent"])
        #expect(!sink.requests.contains { if case .callbackResult = $0 { true } else { false } })
    }

    // MARK: render / on

    @Test func renderReachesTheSink() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("viewOpened", (agent, slot) => {
          leo.render(slot, { type: "Loading" });
        });
        """)
        runtime.deliver(.viewOpened(agent: agent, slot: viewSlot))
        let expected = try LeoPluginSlotRoot(nodes: [.loading(.init(message: nil))])
        #expect(sink.requests == [.render(slot: viewSlot, node: expected)])
    }

    @Test func eventsDeliverTheirArguments() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", (slot) => leo.log("info", "activate " + slot.kind + "/" + slot.id));
        leo.on("agentsChanged", () => leo.log("info", "agents"));
        leo.on("command", (id, slot) => leo.log("info", "command " + id + " " + slot.commandID));
        """)
        runtime.deliver(.activate(slot: .section(id: "issues")))
        runtime.deliver(.agentsChanged)
        runtime.deliver(.command(id: "open", slot: .palette(commandID: "open")))
        #expect(sink.logs == ["activate section/issues", "agents", "command open open"])
    }

    @Test func unknownEventNameThrowsAtLoad() {
        let sink = Sink()
        let runtime = try? LeoPluginJSRuntime(send: { sink.requests.append($0) })
        #expect(throws: LeoPluginRuntimeError.self) {
            try runtime?.load(source: #"leo.on("sendToAgent", () => {})"#)
        }
    }

    // MARK: fetch / secrets / agents

    @Test func fetchResolvesWithTheReply() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", () => {
          leo.fetch("https://api.github.com/user", { method: "POST", headers: { A: "b" }, body: "x" })
            .then(r => leo.log("info", "status " + r.status + " " + r.body));
        });
        """)
        runtime.deliver(.activate(slot: nil))
        guard case .fetch(let id, let url, let fetchInit)? = sink.requests.first else {
            Issue.record("no fetch request"); return
        }
        #expect(url == "https://api.github.com/user")
        #expect(fetchInit == LeoPluginFetchInit(method: "POST", headers: ["A": "b"], body: "x"))
        runtime.deliver(.reply(id: id, outcome: .value(.object(["status": .int(200), "body": .string("ok")]))))
        #expect(sink.logs == ["status 200 ok"])
    }

    @Test func fetchRejectsWithTheReason() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", () => {
          leo.fetch("https://evil.example/x").catch(e => leo.log("info", "rejected: " + e.message));
        });
        """)
        runtime.deliver(.activate(slot: nil))
        guard case .fetch(let id, _, _)? = sink.requests.first else { Issue.record("no fetch"); return }
        runtime.deliver(.reply(id: id, outcome: .rejected(reason: "host not allowed")))
        #expect(sink.logs == ["rejected: host not allowed"])
    }

    @Test func fetchWithBadArgumentsRejectsWithoutReachingTheApp() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", async () => {
          for (const bad of [() => leo.fetch(42), () => leo.fetch("https://x.test", { headers: { a: 1 } })]) {
            try { await bad(); } catch (e) { leo.log("info", e.name); }
          }
        });
        """)
        runtime.deliver(.activate(slot: nil))
        #expect(sink.logs == ["TypeError", "TypeError"])
        #expect(!sink.requests.contains { if case .fetch = $0 { true } else { false } })
    }

    @Test func secretsAndAgentsGoThroughTheBridge() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", async () => {
          await leo.secrets.set("token", "v");
          leo.log("info", "got " + await leo.secrets.get("token"));
          await leo.secrets.delete("token");
          leo.log("info", "agents " + (await leo.agents.list()).length);
        });
        """)
        // Ids of the nth request that carries one (log lines in between don't count).
        func id(_ index: Int) -> String {
            let withIDs = sink.requests.filter { if case .log = $0 { false } else { true } }
            return switch withIDs[index] {
            case .secretsSet(let id, _, _), .secretsGet(let id, _), .secretsDelete(let id, _), .agentsList(let id): id
            default: ""
            }
        }
        runtime.deliver(.activate(slot: nil))
        #expect(sink.requests.first == .secretsSet(id: id(0), key: "token", value: "v"))
        runtime.deliver(.reply(id: id(0), outcome: .value(.null)))
        #expect(sink.requests.count == 2)
        runtime.deliver(.reply(id: id(1), outcome: .value(.string("v"))))
        runtime.deliver(.reply(id: id(2), outcome: .value(.null)))
        runtime.deliver(.reply(id: id(3), outcome: .value(.array([.object([:]), .object([:])]))))
        #expect(sink.logs == ["got v", "agents 2"])
    }

    @Test func agentsExposesExactlyListAndUsage() throws {
        let (_, sink) = try makeRuntime(#"leo.log("info", Object.keys(leo.agents).sort().join(","));"#)
        #expect(sink.logs == ["list,usage"])
    }

    @Test func agentsUsageSendsTheAgentRefAndResolvesWithTheReply() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", async () => {
          const u = await leo.agents.usage({ machine: "local", name: "alfred", extra: "dropped" });
          leo.log("info", "usage " + JSON.stringify(u));
        });
        """)
        runtime.deliver(.activate(slot: nil))
        guard case .agentsUsage(let id, let ref)? = sink.requests.first else {
            Issue.record("expected agentsUsage, got \(sink.requests)")
            return
        }
        #expect(ref == agent)
        runtime.deliver(.reply(id: id, outcome: .value(.object(["model": .string("m")]))))
        #expect(sink.logs == [#"usage {"model":"m"}"#])
    }

    @Test func agentsUsageRejectsAMalformedAgentWithoutSendingAnything() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", async () => {
          for (const bad of [undefined, null, "alfred", {}, { machine: "m" }, { machine: 1, name: "a" }, { machine: "m", name: {} }]) {
            try { await leo.agents.usage(bad); leo.log("info", "no error"); }
            catch (e) { leo.log("info", e.name); }
          }
        });
        """)
        runtime.deliver(.activate(slot: nil))
        #expect(sink.logs == Array(repeating: "TypeError", count: 7))
        #expect(!sink.requests.contains { if case .agentsUsage = $0 { true } else { false } })
    }

    @Test func aRejectedUsageReplySurfacesAsAnError() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("activate", async () => {
          try { await leo.agents.usage({ machine: "local", name: "alfred" }); }
          catch (e) { leo.log("info", "rejected " + e.message); }
        });
        """)
        runtime.deliver(.activate(slot: nil))
        guard case .agentsUsage(let id, _)? = sink.requests.first else { Issue.record("no request"); return }
        runtime.deliver(.reply(id: id, outcome: .rejected(reason: "permission denied")))
        #expect(sink.logs == ["rejected permission denied"])
    }

    @Test func usageChangedIsDeliveredToItsHandlerWithTheAgentRef() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("usageChanged", (agent) => leo.log("info", "usage " + agent.machine + "/" + agent.name));
        """)
        runtime.deliver(.usageChanged(agent: agent))
        #expect(sink.logs == ["usage local/alfred"])
    }

    // MARK: callbacks and follow-ups

    @Test func callbackDeliversIdAndPayload() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("callback", (id, payload) => { leo.log("info", id + ":" + payload.n); });
        """)
        runtime.deliver(.callback(ref: "c1", id: "refresh", payload: .object(["n": .int(7)]), gesture: false))
        #expect(sink.logs == ["refresh:7"])
        #expect(sink.requests.count == 1) // handler returned nothing: no follow-up
    }

    @Test func callbackReturnValueBecomesTheFollowUp() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("callback", (id) => ({ type: "sendToAgent", agent: { machine: "local", name: "alfred" }, text: id }));
        """)
        runtime.deliver(.callback(ref: "c9", id: "go", payload: .null, gesture: true))
        #expect(sink.requests == [.callbackResult(ref: "c9", action: .sendToAgent(agent: agent, text: "go"))])
    }

    @Test func asyncCallbackFollowUpArrivesAfterTheReply() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("callback", async (id) => {
          const r = await leo.fetch("https://api.github.com/log");
          return { type: "sendToAgent", agent: { machine: "local", name: "alfred" }, text: r.body };
        });
        """)
        runtime.deliver(.callback(ref: "c2", id: "send-failure", payload: .null, gesture: true))
        guard case .fetch(let id, _, _)? = sink.requests.first else { Issue.record("no fetch"); return }
        runtime.deliver(.reply(id: id, outcome: .value(.object(["status": .int(200), "body": .string("boom")]))))
        #expect(sink.requests.last == .callbackResult(ref: "c2", action: .sendToAgent(agent: agent, text: "boom")))
    }

    @Test func malformedFollowUpIsReportedNotForwarded() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("callback", () => ({ type: "runShell", cmd: "ls" }));
        """)
        runtime.deliver(.callback(ref: "c3", id: "x", payload: .null, gesture: true))
        #expect(sink.errors.count == 1)
        #expect(!sink.requests.contains { if case .callbackResult = $0 { true } else { false } })
    }

    // MARK: timers

    @Test func timerAndAfterFireAndCancel() throws {
        let (runtime, sink) = try makeRuntime("""
        let n = 0;
        const t = leo.timer(60, () => { n += 1; leo.log("info", "tick " + n); });
        leo.after(5, () => leo.log("info", "after"));
        leo.on("activate", () => t.cancel());
        """)
        guard case .timerStart(let tid, let tsec) = sink.requests[0],
              case .afterStart(let aid, let asec) = sink.requests[1] else { Issue.record("no timers"); return }
        #expect(tsec == 60)
        #expect(asec == 5)
        runtime.deliver(.timerFired(id: tid))
        runtime.deliver(.timerFired(id: tid))
        runtime.deliver(.timerFired(id: aid))
        runtime.deliver(.timerFired(id: aid)) // one-shot: second fire is ignored
        #expect(sink.logs == ["tick 1", "tick 2", "after"])
        runtime.deliver(.activate(slot: nil))
        #expect(sink.requests.last == .timerStop(id: tid))
        runtime.deliver(.timerFired(id: tid))
        #expect(sink.logs.count == 3)
    }

    @Test func timerBelowMinimumThrowsInPluginCode() throws {
        let (_, sink) = try makeRuntime("""
        for (const f of [() => leo.timer(59, () => {}), () => leo.after(0.5, () => {})]) {
          try { f(); } catch (e) { leo.log("info", e.name); }
        }
        """)
        #expect(sink.logs == ["RangeError", "RangeError"])
        #expect(sink.requests.count == 2) // only the logs
    }

    // MARK: errors

    @Test func uncaughtHandlerExceptionIsReportedAsHandlerError() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("agentsChanged", () => { throw new Error("kaboom"); });
        leo.on("activate", () => leo.log("info", "still alive"));
        """)
        runtime.deliver(.agentsChanged)
        runtime.deliver(.activate(slot: nil))
        #expect(sink.errors == ["kaboom"])
        #expect(sink.logs == ["still alive"])
    }

    @Test func asyncHandlerRejectionIsReported() throws {
        let (runtime, sink) = try makeRuntime("""
        leo.on("agentsChanged", async () => { throw new Error("async kaboom"); });
        """)
        runtime.deliver(.agentsChanged)
        #expect(sink.errors == ["async kaboom"])
    }

    @Test func loadFailureThrows() {
        let sink = Sink()
        let runtime = try? LeoPluginJSRuntime(send: { sink.requests.append($0) })
        #expect(throws: LeoPluginRuntimeError.self) { try runtime?.load(source: "this is not js (") }
        #expect(throws: LeoPluginRuntimeError.self) { try runtime?.load(source: #"throw new Error("bad")"#) }
    }
}
