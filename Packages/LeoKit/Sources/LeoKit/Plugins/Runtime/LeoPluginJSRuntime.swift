import Foundation
import JavaScriptCore

public enum LeoPluginRuntimeError: Error, Equatable, Sendable {
    /// The fresh context already had a global a plugin must never see.
    case forbiddenGlobal(String)
    case setupFailed(String)
    /// The plugin bundle threw (or failed to parse) while loading.
    case loadFailed(String)
}

/// One plugin's JavaScriptCore context.
///
/// The context exposes a single frozen `leo` object (`render`, `on`, `fetch`,
/// `secrets`, `agents`, `timer`, `after`, `log`) and nothing else from the
/// host: no `fetch`, `XMLHttpRequest`, `require`, `process`, timers or
/// console. Everything plugin code asks for leaves through the injected
/// `send` as a `LeoPluginHostRequest`; the app answers with
/// `deliver(.reply(...))`. Promise reactions run when `deliver` returns
/// control to JavaScriptCore, so replies, handler errors and follow-ups all
/// surface synchronously from the caller's point of view.
///
/// Not thread-safe: use from one queue (the XPC service's), and expect
/// `send` to be invoked re-entrantly from inside `load` and `deliver`.
public final class LeoPluginJSRuntime {
    /// Names that must not exist in the context. A bare JSC context has none
    /// of them; checking turns an accidental future leak into a hard failure.
    static let forbiddenGlobals = [
        "fetch", "XMLHttpRequest", "require", "process", "module", "exports",
        "WebSocket", "importScripts", "setTimeout", "setInterval",
    ]

    private let context: JSContext
    private let send: (LeoPluginHostRequest) -> Void
    private var dispatch: JSValue?
    private var lastException: String?

    public init(send: @escaping (LeoPluginHostRequest) -> Void) throws {
        guard let context = JSContext() else { throw LeoPluginRuntimeError.setupFailed("no JSContext") }
        self.context = context
        self.send = send
        context.exceptionHandler = { [weak self] _, exception in
            self?.lastException = exception?.toString() ?? "unknown JavaScript error"
        }
        try assertNoForbiddenGlobals()
        try installBridge()
    }

    /// Evaluates the plugin's bundle. Handlers it registers via `leo.on`
    /// run on later `deliver` calls.
    public func load(source: String) throws {
        lastException = nil
        context.evaluateScript(source)
        if let message = takeException() { throw LeoPluginRuntimeError.loadFailed(message) }
    }

    /// Hands an app event to plugin code. Failures inside plugin code are
    /// reported through `send` as `.handlerError`, never thrown.
    public func deliver(_ event: LeoPluginEvent) {
        guard let dispatch,
              let data = try? JSONEncoder().encode(event),
              let json = String(data: data, encoding: .utf8)
        else { return }
        lastException = nil
        dispatch.call(withArguments: [json])
        if let message = takeException() {
            send(.handlerError(source: "runtime", message: message))
        }
    }

    // MARK: Private

    private func assertNoForbiddenGlobals() throws {
        for name in Self.forbiddenGlobals {
            let present = context.evaluateScript("typeof globalThis[\"\(name)\"] !== \"undefined\"")?.toBool() ?? false
            if present { throw LeoPluginRuntimeError.forbiddenGlobal(name) }
        }
    }

    private func installBridge() throws {
        let post: @convention(block) (String) -> Void = { [weak self] json in
            self?.receive(json: json)
        }
        guard let factory = context.evaluateScript(LeoPluginJSPrelude.source),
              let dispatch = factory.call(withArguments: [unsafeBitCast(post, to: AnyObject.self)]),
              dispatch.isObject
        else { throw LeoPluginRuntimeError.setupFailed(takeException() ?? "prelude failed") }
        self.dispatch = dispatch
    }

    private func receive(json: String) {
        do {
            send(try LeoPluginFrame.decodeRequest(json))
        } catch {
            send(.handlerError(source: "bridge", message: "malformed request: \(error)"))
        }
    }

    private func takeException() -> String? {
        defer { lastException = nil }
        return lastException
    }
}
