/// The only JavaScript Leo itself puts in a plugin's context. It is a
/// function expression: Swift calls it once with a native `post` block and
/// keeps the `dispatch` function it returns. Neither `post` nor `dispatch`
/// is ever a global, so plugin code cannot reach the native side except
/// through the frozen `leo` object defined here.
///
/// `leo` has no `sendToAgent` / `spawnAgent`. Those exist only as action
/// shapes plugin code returns from a `callback` handler.
enum LeoPluginJSPrelude {
    static let source = #"""
    (function (post) {
      "use strict";
      const stringify = JSON.stringify;
      const parse = JSON.parse;
      const resolveValue = Promise.resolve.bind(Promise);
      const EVENTS = ["activate", "agentsChanged", "viewOpened", "command", "callback"];
      const MIN_TIMER_SECONDS = 60;
      const MIN_AFTER_SECONDS = 1;

      const handlers = Object.create(null);
      const pending = new Map();
      const timers = new Map();
      let seq = 0;

      const send = (message) => post(stringify(message));
      const describe = (e) => String(e && e.message !== undefined ? e.message : e);
      const report = (source, e) => send({ call: "handlerError", source: source, message: describe(e) });
      const nextID = (prefix) => prefix + String(++seq);

      function request(message) {
        return new Promise((resolve, reject) => {
          const id = nextID("r");
          pending.set(id, { resolve: resolve, reject: reject });
          send(Object.assign({ id: id }, message));
        });
      }

      function checkedFetchInit(init) {
        if (init === undefined || init === null) return {};
        if (typeof init !== "object") throw new TypeError("fetch init must be an object");
        const out = {};
        if (init.method !== undefined) {
          if (typeof init.method !== "string") throw new TypeError("fetch method must be a string");
          out.method = init.method;
        }
        if (init.body !== undefined) {
          if (typeof init.body !== "string") throw new TypeError("fetch body must be a string");
          out.body = init.body;
        }
        if (init.headers !== undefined) {
          if (init.headers === null || typeof init.headers !== "object") {
            throw new TypeError("fetch headers must be an object");
          }
          const headers = {};
          for (const name of Object.keys(init.headers)) {
            if (typeof init.headers[name] !== "string") throw new TypeError("fetch header values must be strings");
            headers[name] = init.headers[name];
          }
          out.headers = headers;
        }
        return out;
      }

      // Only the two string fields cross the bridge; anything else on the object is dropped.
      function checkedAgentRef(agent) {
        if (agent === null || typeof agent !== "object" || typeof agent.machine !== "string" || typeof agent.name !== "string") {
          throw new TypeError("an agent must be { machine: string, name: string }");
        }
        return { machine: agent.machine, name: agent.name };
      }

      function startTimer(kind, call, minimum, seconds, fn) {
        if (typeof seconds !== "number" || !isFinite(seconds) || seconds < minimum) {
          throw new RangeError("leo." + kind + " needs at least " + minimum + " seconds");
        }
        if (typeof fn !== "function") throw new TypeError("leo." + kind + " needs a function");
        const id = nextID("t");
        timers.set(id, { fn: fn, repeat: kind === "timer" });
        send({ call: call, id: id, seconds: seconds });
        return Object.freeze({
          cancel: function () {
            if (timers.delete(id)) send({ call: "timerStop", id: id });
          }
        });
      }

      // Handlers may be async: a rejected promise is a handler error too.
      function watch(source, result) {
        if (result && typeof result.then === "function") {
          result.then(undefined, (e) => report(source, e));
        }
      }

      function followUp(ref, result) {
        if (result === undefined || result === null) return;
        resolveValue(result).then(
          (action) => {
            if (action !== undefined && action !== null) send({ call: "callbackResult", ref: ref, action: action });
          },
          (e) => report("callback", e)
        );
      }

      const leo = Object.freeze({
        render: function (slot, tree) { send({ call: "render", slot: slot, node: tree }); },
        on: function (event, fn) {
          if (EVENTS.indexOf(event) < 0) throw new TypeError("unknown event: " + String(event));
          if (typeof fn !== "function") throw new TypeError("leo.on needs a function");
          handlers[event] = fn;
        },
        fetch: function (url, init) {
          try {
            if (typeof url !== "string") throw new TypeError("fetch url must be a string");
            return request({ call: "fetch", url: url, init: checkedFetchInit(init) });
          } catch (e) {
            return Promise.reject(e);
          }
        },
        secrets: Object.freeze({
          get: (key) => request({ call: "secretsGet", key: String(key) }),
          set: (key, value) => request({ call: "secretsSet", key: String(key), value: String(value) }),
          delete: (key) => request({ call: "secretsDelete", key: String(key) })
        }),
        agents: Object.freeze({
          list: () => request({ call: "agentsList" }),
          usage: function (agent) {
            try {
              return request({ call: "agentsUsage", agent: checkedAgentRef(agent) });
            } catch (e) {
              return Promise.reject(e);
            }
          }
        }),
        timer: (seconds, fn) => startTimer("timer", "timerStart", MIN_TIMER_SECONDS, seconds, fn),
        after: (seconds, fn) => startTimer("after", "afterStart", MIN_AFTER_SECONDS, seconds, fn),
        log: function (level, message) { send({ call: "log", level: String(level), message: String(message) }); }
      });
      Object.defineProperty(globalThis, "leo", { value: leo, writable: false, configurable: false, enumerable: true });

      function dispatch(json) {
        const ev = parse(json);
        try {
          switch (ev.type) {
            case "reply": {
              const entry = pending.get(ev.id);
              if (!entry) return;
              pending.delete(ev.id);
              if (ev.outcome === "rejected") entry.reject(new Error(ev.reason));
              else entry.resolve(ev.value);
              return;
            }
            case "timerFired": {
              const timer = timers.get(ev.id);
              if (!timer) return;
              if (!timer.repeat) timers.delete(ev.id);
              watch("timerFired", timer.fn());
              return;
            }
            case "callback": {
              const handler = handlers.callback;
              if (handler) followUp(ev.ref, handler(ev.id, ev.payload));
              return;
            }
            case "activate": if (handlers.activate) watch(ev.type, handlers.activate(ev.slot)); return;
            case "agentsChanged": if (handlers.agentsChanged) watch(ev.type, handlers.agentsChanged()); return;
            case "viewOpened": if (handlers.viewOpened) watch(ev.type, handlers.viewOpened(ev.agent, ev.slot)); return;
            case "command": if (handlers.command) watch(ev.type, handlers.command(ev.id, ev.slot)); return;
          }
        } catch (e) {
          report(ev.type, e);
        }
      }
      return dispatch;
    })
    """#
}
