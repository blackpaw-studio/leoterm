"use strict";
(() => {
  // src/clock.ts
  var systemClock = { now: () => Date.now() };

  // src/window.ts
  var clampPercent = (n) => Math.min(100, Math.max(0, n));
  var isRecord = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
  var finiteNumber = (v) => typeof v === "number" && Number.isFinite(v) ? v : void 0;
  var makeWindow = (key, label, percent, resetsAtMs) => resetsAtMs === void 0 ? { key, label, percent: clampPercent(percent) } : { key, label, percent: clampPercent(percent), resetsAtMs };

  // src/parse/claude.ts
  var WINDOWS = [
    ["five_hour", "session", "Session"],
    ["seven_day", "weekly", "Weekly"],
    ["seven_day_opus", "weekly-opus", "Weekly Opus"],
    ["seven_day_sonnet", "weekly-sonnet", "Weekly Sonnet"]
  ];
  var parseIso = (v) => {
    if (typeof v !== "string") return void 0;
    const ms = Date.parse(v);
    return Number.isNaN(ms) ? void 0 : ms;
  };
  function parseClaude(body) {
    if (!isRecord(body)) return [];
    return WINDOWS.flatMap(([field, key, label]) => {
      const w = body[field];
      if (!isRecord(w)) return [];
      const percent = finiteNumber(w.utilization);
      return percent === void 0 ? [] : [makeWindow(key, label, percent, parseIso(w.resets_at))];
    });
  }

  // src/parse/codex.ts
  var WINDOWS2 = [
    ["primary_window", "session", "Session"],
    ["secondary_window", "weekly", "Weekly"]
  ];
  function parseCodex(body) {
    if (!isRecord(body) || !isRecord(body.rate_limit)) return [];
    const limit = body.rate_limit;
    return WINDOWS2.flatMap(([field, key, label]) => {
      const w = limit[field];
      if (!isRecord(w)) return [];
      const percent = finiteNumber(w.used_percent);
      const resetAt = finiteNumber(w.reset_at);
      return percent === void 0 ? [] : [makeWindow(key, label, percent, resetAt === void 0 ? void 0 : resetAt * 1e3)];
    });
  }

  // src/state.ts
  var BACKOFF_MS = 15 * 6e4;
  var NO_DATA = "No usage data";
  var initialState = () => ({ status: "loading", windows: [] });
  var degrade = (state, message, extra = {}) => state.windows.length > 0 ? { ...state, ...extra, status: "stale", message } : { windows: [], ...extra, status: "error", message };
  function reduce(state, outcome, nowMs) {
    switch (outcome.kind) {
      case "ok":
        return outcome.windows.length === 0 ? { status: "error", windows: [], message: NO_DATA } : { status: "ok", windows: outcome.windows, updatedAtMs: nowMs };
      case "unauthorized":
        return { status: "expired", windows: [] };
      case "needsAuthorization":
        return { status: "needsAuthorization", windows: [] };
      case "rateLimited":
        return degrade(state, "Rate limited", { backoffUntilMs: nowMs + BACKOFF_MS });
      case "failed":
        return degrade(state, outcome.message);
    }
  }
  var isDue = (state, nowMs) => state.backoffUntilMs === void 0 || nowMs >= state.backoffUntilMs;

  // src/store.ts
  var STATE_KEY = "state";
  var MAX_STATE_CHARS = 15e3;
  var MAX_LABEL_CHARS = 60;
  var emptyPersisted = () => ({ order: [], labels: {}, snapshots: {} });
  var WINDOW_KEYS = /* @__PURE__ */ new Set(["session", "weekly", "weekly-opus", "weekly-sonnet"]);
  var readWindow = (v) => {
    if (!isRecord(v) || typeof v.key !== "string" || !WINDOW_KEYS.has(v.key) || typeof v.label !== "string") return [];
    const percent = finiteNumber(v.percent);
    if (percent === void 0) return [];
    const resetsAtMs = finiteNumber(v.resetsAtMs);
    const base = { key: v.key, label: v.label, percent };
    return [resetsAtMs === void 0 ? base : { ...base, resetsAtMs }];
  };
  var readSnapshot = (v) => {
    if (!isRecord(v) || !Array.isArray(v.windows)) return [];
    const updatedAtMs = finiteNumber(v.updatedAtMs);
    return updatedAtMs === void 0 ? [] : [{ windows: v.windows.flatMap(readWindow), updatedAtMs }];
  };
  function sanitize(raw) {
    if (!isRecord(raw)) return emptyPersisted();
    const order = Array.isArray(raw.order) ? raw.order.filter((id) => typeof id === "string") : [];
    const labels = isRecord(raw.labels) ? Object.fromEntries(
      Object.entries(raw.labels).filter((e) => typeof e[1] === "string").map(([id, label]) => [id, label.slice(0, MAX_LABEL_CHARS)])
    ) : {};
    const snapshots = isRecord(raw.snapshots) ? Object.fromEntries(Object.entries(raw.snapshots).flatMap(([id, s]) => readSnapshot(s).map((snap) => [id, snap]))) : {};
    return { order, labels, snapshots };
  }
  async function loadPersisted(leo2) {
    const raw = await leo2.secrets.get(STATE_KEY);
    if (raw === null) return emptyPersisted();
    try {
      return sanitize(JSON.parse(raw));
    } catch {
      return emptyPersisted();
    }
  }
  function fit(state) {
    const byAge = Object.entries(state.snapshots).sort((a, b) => a[1].updatedAtMs - b[1].updatedAtMs);
    const trimmed = (dropped) => ({ ...state, snapshots: Object.fromEntries(byAge.slice(dropped)) });
    for (let dropped = 0; dropped <= byAge.length; dropped += 1) {
      const candidate = trimmed(dropped);
      if (JSON.stringify(candidate).length <= MAX_STATE_CHARS) return candidate;
    }
    return trimmed(byAge.length);
  }
  async function savePersisted(leo2, state) {
    await leo2.secrets.set(STATE_KEY, JSON.stringify(fit(sanitize(state))));
  }

  // src/poller.ts
  var CLAUDE_URL = "https://api.anthropic.com/api/oauth/usage";
  var CODEX_URL = "https://chatgpt.com/backend-api/wham/usage";
  var POLL_INTERVAL_SEC = 300;
  var PROVIDERS = {
    "claude-code": { url: CLAUDE_URL, parse: parseClaude },
    codex: { url: CODEX_URL, parse: parseCodex }
  };
  var defaultLabel = (handle) => handle.label.startsWith(".") ? handle.label.slice(1) : handle.label;
  var errorMessage = (e) => e instanceof Error ? e.message : String(e);
  async function fetchOutcome(leo2, handle) {
    const provider = PROVIDERS[handle.kind];
    try {
      const res = await leo2.fetch(provider.url, { credential: handle.id, headers: { Accept: "application/json" } });
      if (res.status === 401) return { kind: "unauthorized" };
      if (res.status === 429) return { kind: "rateLimited" };
      if (res.status !== 200) return { kind: "failed", message: "HTTP " + res.status };
      try {
        return { kind: "ok", windows: provider.parse(JSON.parse(res.body)) };
      } catch {
        return { kind: "failed", message: "Unreadable response" };
      }
    } catch (e) {
      const message = errorMessage(e);
      return message.includes("credentialNeedsAuthorization") ? { kind: "needsAuthorization" } : { kind: "failed", message };
    }
  }
  function createPoller(leo2, clock, onChange) {
    let entries = [];
    let persisted = null;
    let inFlight = null;
    const persist = async () => {
      const base = persisted ?? await loadPersisted(leo2);
      persisted = {
        order: entries.map((e) => e.handle.id),
        labels: Object.fromEntries(Object.entries(base.labels).filter(([id]) => entries.some((e) => e.handle.id === id))),
        snapshots: Object.fromEntries(
          entries.flatMap(
            (e) => e.state.windows.length > 0 && e.state.updatedAtMs !== void 0 ? [[e.handle.id, { windows: [...e.state.windows], updatedAtMs: e.state.updatedAtMs }]] : []
          )
        )
      };
      await savePersisted(leo2, persisted);
    };
    const setState = (id, state) => {
      entries = entries.map((e) => e.handle.id === id ? { ...e, state } : e);
      onChange();
    };
    const restore = (handle, saved) => {
      const snap = saved.snapshots[handle.id];
      return snap ? { status: "ok", windows: snap.windows, updatedAtMs: snap.updatedAtMs } : initialState();
    };
    const sync = async () => {
      persisted = persisted ?? await loadPersisted(leo2);
      const saved = persisted;
      const handles = await leo2.credentials.list();
      const rank = (h) => {
        const i = saved.order.indexOf(h.id);
        return i === -1 ? Number.MAX_SAFE_INTEGER : i;
      };
      const ordered = handles.map((h, i) => ({ h, i })).sort((a, b) => rank(a.h) - rank(b.h) || a.i - b.i).map((x) => x.h);
      entries = ordered.map((handle) => ({
        handle,
        state: entries.find((e) => e.handle.id === handle.id)?.state ?? restore(handle, saved)
      }));
      if (JSON.stringify(entries.map((e) => e.handle.id)) !== JSON.stringify(saved.order)) await persist();
      onChange();
    };
    const pass = async (options) => {
      for (const { handle } of [...entries]) {
        const current = entries.find((e) => e.handle.id === handle.id);
        if (!current || !options.force && !isDue(current.state, clock.now())) continue;
        const outcome = await fetchOutcome(leo2, handle);
        if (entries.some((e) => e.handle.id === handle.id)) {
          setState(handle.id, reduce(entries.find((e) => e.handle.id === handle.id)?.state ?? initialState(), outcome, clock.now()));
        }
      }
      await persist();
    };
    let queued = null;
    const run = async (first) => {
      await pass(first);
      while (queued !== null) {
        const next = queued;
        queued = null;
        await pass(next);
      }
    };
    const refresh = (options = {}) => {
      if (inFlight) {
        queued = { force: (queued?.force ?? false) || options.force === true };
        return inFlight;
      }
      inFlight = run(options).finally(() => {
        inFlight = null;
      });
      return inFlight;
    };
    let timer = null;
    return {
      sync,
      refresh,
      start: async () => {
        timer ?? (timer = leo2.timer(POLL_INTERVAL_SEC, async () => {
          try {
            await sync();
            await refresh();
          } catch (e) {
            leo2.log("error", "poll failed: " + errorMessage(e));
          }
        }));
        await sync();
        await refresh();
      },
      accounts: () => entries.map((e) => ({ handle: e.handle, label: persisted?.labels[e.handle.id] ?? defaultLabel(e.handle), state: e.state })),
      rename: async (id, label) => {
        const base = persisted ?? await loadPersisted(leo2);
        const trimmed = label.trim();
        const { [id]: _dropped, ...rest } = base.labels;
        persisted = { ...base, labels: trimmed === "" ? rest : { ...rest, [id]: trimmed } };
        await savePersisted(leo2, persisted);
        onChange();
      },
      forget: async (id) => {
        entries = entries.filter((e) => e.handle.id !== id);
        await persist();
        onChange();
      }
    };
  }

  // src/format.ts
  var MIN = 6e4;
  var HOUR = 60 * MIN;
  var DAY = 24 * HOUR;
  var percentText = (percent) => Math.round(percent) + "%";
  var pair = (big, unit, rest, restUnit) => rest === 0 ? big + unit : big + unit + " " + rest + restUnit;
  var span = (ms) => {
    if (ms < MIN) return "<1m";
    if (ms < HOUR) return Math.floor(ms / MIN) + "m";
    if (ms < DAY) return pair(Math.floor(ms / HOUR), "h", Math.floor(ms % HOUR / MIN), "m");
    return pair(Math.floor(ms / DAY), "d", Math.floor(ms % DAY / HOUR), "h");
  };
  var resetsIn = (resetsAtMs, nowMs) => resetsAtMs <= nowMs ? "Resetting now" : "Resets in " + span(resetsAtMs - nowMs);
  var updatedAgo = (updatedAtMs, nowMs) => {
    const age = Math.max(0, nowMs - updatedAtMs);
    if (age < MIN) return "Updated just now";
    if (age < HOUR) return "Updated " + Math.floor(age / MIN) + "m ago";
    if (age < DAY) return "Updated " + Math.floor(age / HOUR) + "h ago";
    return "Updated " + Math.floor(age / DAY) + "d ago";
  };
  var MAX_HELP_CHARS = 80;
  var MAX_LINE_CHARS = 120;
  var clip = (text, max) => text.length <= max ? text : text.slice(0, max - 1) + "\u2026";
  var clockTime = (ms) => {
    const d = new Date(ms);
    const h = d.getHours();
    const m = d.getMinutes();
    return (h % 12 === 0 ? 12 : h % 12) + ":" + (m < 10 ? "0" : "") + m + (h < 12 ? " AM" : " PM");
  };

  // src/tone.ts
  var WARNING_AT = 75;
  var FAILURE_AT = 90;
  var toneFor = (percent) => percent >= FAILURE_AT ? "failure" : percent >= WARNING_AT ? "warning" : "success";
  var RANK = { neutral: 0, success: 1, warning: 2, failure: 3 };
  var worstTone = (tones) => tones.reduce((worst, t) => worst === void 0 || RANK[t] > RANK[worst] ? t : worst, void 0);
  var highestWindow = (windows) => windows.reduce((best, w) => best === void 0 || w.percent > best.percent ? w : best, void 0);

  // src/views.ts
  var CALLBACKS = {
    refresh: "refresh",
    add: "add",
    authorize: "authorize",
    remove: "remove",
    rename: "rename"
  };
  var KIND_SYMBOL = { "claude-code": "bubble.left.fill", codex: "terminal" };
  var KIND_NAME = { "claude-code": "Claude Code", codex: "Codex" };
  var KIND_COMMAND = { "claude-code": "claude", codex: "codex" };
  var HEADER_SYMBOL = "speedometer";
  var callback = (id, title, sfSymbol, payload) => ({
    type: "callback",
    id,
    title,
    sfSymbol,
    ...payload ? { payload } : {}
  });
  var addActions = [
    callback(CALLBACKS.add, "Add Claude Account\u2026", "plus.circle", { kind: "claude-code" }),
    callback(CALLBACKS.add, "Add Codex Account\u2026", "plus.circle", { kind: "codex" })
  ];
  var refreshAction = callback(CALLBACKS.refresh, "Refresh", "arrow.clockwise");
  var accessory = (sfSymbol, text, color) => ({ type: "Accessory", sfSymbol, text, color });
  var emptyState = () => ({
    type: "EmptyState",
    title: "No accounts yet",
    message: "Add a Claude Code or Codex account to see its rate-limit usage.",
    sfSymbol: "plus.circle",
    actions: addActions
  });
  var meter = (w, nowMs, detail) => ({
    type: "Meter",
    label: w.label,
    value: w.percent / 100,
    valueText: percentText(w.percent),
    ...detail !== void 0 ? { detail } : w.resetsAtMs !== void 0 ? { detail: resetsIn(w.resetsAtMs, nowMs) } : {},
    tone: toneFor(w.percent)
  });
  var stateAccessory = (state) => {
    switch (state.status) {
      case "stale":
        return { ...accessory("arrow.clockwise", "Stale", "warning"), ...state.message !== void 0 ? { help: clip(state.message, MAX_HELP_CHARS) } : {} };
      case "expired":
        return accessory("xmark.circle", "Expired", "failure");
      case "needsAuthorization":
        return accessory("lock.fill", "Locked", "warning");
      case "error":
        return accessory("exclamationmark.triangle", "Error", "warning");
      default:
        return void 0;
    }
  };
  var stateText = (account) => {
    const { handle, state } = account;
    switch (state.status) {
      case "loading":
        return "Loading\u2026";
      case "expired":
        return "Signed out \u2014 run " + KIND_COMMAND[handle.kind] + " with this account to refresh";
      case "needsAuthorization":
        return handle.kind === "claude-code" ? "Leo needs Keychain access to read this account" : "Leo needs access to read this account";
      case "error":
        return clip(state.message ?? NO_DATA, MAX_LINE_CHARS);
      default:
        return void 0;
    }
  };
  var signInCommand = (account) => {
    const { kind, path } = account.handle;
    return kind === "claude-code" ? "CLAUDE_CONFIG_DIR=" + path + " claude" : "CODEX_HOME=" + path + " codex login";
  };
  var leadingActions = (account) => {
    switch (account.state.status) {
      case "expired":
        return [{ type: "copy", title: "Copy Sign-in Command", sfSymbol: "doc", text: signInCommand(account) }];
      case "needsAuthorization":
        return [callback(CALLBACKS.authorize, "Grant Access\u2026", "key", { id: account.handle.id })];
      default:
        return [];
    }
  };
  var staleDetail = (state, nowMs) => state.status === "stale" && state.updatedAtMs !== void 0 ? "Couldn't refresh \xB7 values from " + clockTime(state.updatedAtMs) : void 0;
  var renameForm = (account) => ({
    type: "Form",
    id: CALLBACKS.rename,
    title: "Rename Account",
    fields: [
      { id: "label", type: "text", label: "Name", value: account.label },
      {
        id: "submit",
        type: "submit",
        label: "Rename",
        action: { type: "callback", id: CALLBACKS.rename, payload: { id: account.handle.id } }
      }
    ]
  });
  var group = (account, children, subtitle, actions) => {
    const acc = stateAccessory(account.state);
    return {
      type: "Group",
      title: account.label,
      ...subtitle !== void 0 ? { subtitle } : {},
      sfSymbol: KIND_SYMBOL[account.handle.kind],
      ...acc ? { accessory: acc } : {},
      children,
      actions
    };
  };
  var sidebarGroup = (account, nowMs) => {
    const top = highestWindow(account.state.windows);
    const children = top ? [meter(top, nowMs, staleDetail(account.state, nowMs))] : [];
    const text = children.length === 0 ? stateText(account) : void 0;
    const kind = KIND_NAME[account.handle.kind];
    const subtitle = clip(text === void 0 ? kind : kind + " \xB7 " + text, MAX_LINE_CHARS);
    return group(account, children, subtitle, [...leadingActions(account), refreshAction, ...addActions]);
  };
  var fullGroup = (account, nowMs) => {
    const { state, handle } = account;
    const updated = state.updatedAtMs !== void 0 && state.windows.length > 0 ? updatedAgo(state.updatedAtMs, nowMs) : stateText(account);
    const subtitle = clip(updated === void 0 ? handle.path : handle.path + " \xB7 " + updated, MAX_LINE_CHARS);
    const detail = staleDetail(state, nowMs);
    return group(
      account,
      state.windows.map((w) => meter(w, nowMs, detail)),
      subtitle,
      [
        ...leadingActions(account),
        refreshAction,
        { type: "pushView", title: "Rename\u2026", sfSymbol: "tag", node: renameForm(account) },
        callback(CALLBACKS.remove, "Remove", "minus.circle", { id: handle.id })
      ]
    );
  };
  var ACCESSORY_COLOR = {
    neutral: "neutral",
    success: "success",
    warning: "warning",
    failure: "failure"
  };
  var headerAccessory = (accounts) => {
    const tops = accounts.flatMap((a) => {
      const top = highestWindow(a.state.windows);
      return top ? [top] : [];
    });
    const worst = highestWindow(tops);
    if (!worst) return [];
    const tone = worstTone(tops.map((w) => toneFor(w.percent))) ?? "neutral";
    return [
      {
        type: "Accessory",
        sfSymbol: HEADER_SYMBOL,
        text: percentText(worst.percent),
        color: ACCESSORY_COLOR[tone],
        help: "Highest usage across accounts: " + worst.label
      }
    ];
  };
  function sidebarRoot(accounts, nowMs) {
    if (accounts.length === 0) return emptyState();
    const nodes = [...headerAccessory(accounts), ...accounts.map((a) => sidebarGroup(a, nowMs))];
    return nodes;
  }
  function fullRoot(accounts, nowMs) {
    if (accounts.length === 0) return emptyState();
    return accounts.map((a) => fullGroup(a, nowMs));
  }

  // src/plugin.ts
  var SECTION_ID = "usage";
  var COMMANDS = {
    show: "show",
    addClaude: "add-claude",
    addCodex: "add-codex",
    refresh: "refresh"
  };
  var KINDS = ["claude-code", "codex"];
  var isObj = (v) => typeof v === "object" && v !== null && !Array.isArray(v);
  var asKind = (v) => KINDS.find((k) => k === v) ?? null;
  var str = (v) => typeof v === "string" ? v : null;
  var note = (title, message, sfSymbol) => ({
    type: "EmptyState",
    title,
    ...message !== void 0 ? { message } : {},
    ...sfSymbol !== void 0 ? { sfSymbol } : {}
  });
  function createPlugin(leo2, clock) {
    const sections = /* @__PURE__ */ new Map();
    let showSlot = null;
    let started = null;
    const draw = () => {
      const accounts = poller.accounts();
      sections.forEach((slot) => leo2.render(slot, sidebarRoot(accounts, clock.now())));
      if (showSlot) leo2.render(showSlot, fullRoot(accounts, clock.now()));
    };
    const poller = createPoller(leo2, clock, draw);
    const start = () => {
      started = started ?? poller.start().catch((e) => {
        started = null;
        throw e;
      });
      return started;
    };
    const safely = (what, fn) => async (...args) => {
      try {
        return await fn(...args);
      } catch (e) {
        leo2.log("error", what + " failed: " + (e instanceof Error ? e.message : String(e)));
        return void 0;
      }
    };
    const addAccount = async (kind, slot) => {
      const pending = leo2.credentials.add(kind);
      const handle = await pending;
      if (slot?.kind === "palette") {
        leo2.render(slot, handle ? note("Added " + handle.label, handle.path, "checkmark.circle.fill") : note("No account added", void 0, "xmark.circle"));
      }
      if (!handle) return;
      await poller.sync();
      await poller.refresh({ force: true });
    };
    const authorize = async (id) => {
      const pending = leo2.credentials.authorize(id);
      await pending;
      await poller.refresh({ force: true });
    };
    const activate = async (slot) => {
      if (slot?.kind === "section" && slot.id === SECTION_ID) sections.set(JSON.stringify(slot), slot);
      await start();
      draw();
    };
    const command = (id, slot) => {
      switch (id) {
        case COMMANDS.addClaude:
          return addAccount("claude-code", slot);
        case COMMANDS.addCodex:
          return addAccount("codex", slot);
        case COMMANDS.show:
          return showUsage(slot);
        case COMMANDS.refresh:
          return refreshNow(slot);
        default:
          return Promise.resolve();
      }
    };
    const showUsage = async (slot) => {
      if (slot?.kind === "palette") showSlot = slot;
      await start();
      draw();
    };
    const refreshNow = async (slot) => {
      await start();
      await poller.refresh({ force: true });
      if (slot?.kind === "palette") leo2.render(slot, note("Usage refreshed", void 0, "checkmark.circle.fill"));
    };
    const callbackHandler = (id, payload) => {
      const body = isObj(payload) ? payload : {};
      switch (id) {
        case CALLBACKS.add: {
          const kind = asKind(body.kind);
          return kind ? addAccount(kind).then(() => null) : Promise.resolve(null);
        }
        case CALLBACKS.authorize: {
          const target = str(body.id);
          return target ? authorize(target).then(() => null) : Promise.resolve(null);
        }
        case CALLBACKS.refresh:
          return refreshNow().then(() => null);
        case CALLBACKS.remove: {
          const target = str(body.id);
          return target ? removeAccount(target).then(() => null) : Promise.resolve(null);
        }
        case CALLBACKS.rename: {
          const inner = isObj(body.payload) ? body.payload : {};
          const target = str(inner.id);
          const values = isObj(body.values) ? body.values : {};
          const label = str(values.label);
          return target && label !== null ? poller.rename(target, label).then(() => null) : Promise.resolve(null);
        }
        default:
          return Promise.resolve(null);
      }
    };
    const removeAccount = async (id) => {
      await leo2.credentials.remove(id);
      await poller.forget(id);
    };
    const credentialsChanged = async () => {
      await start();
      await poller.sync();
      await poller.refresh();
    };
    leo2.on("credentialsChanged", safely("credentialsChanged", credentialsChanged));
    leo2.on("activate", safely("activate", activate));
    leo2.on("command", safely("command", command));
    leo2.on("callback", safely("callback", callbackHandler));
  }

  // src/main.ts
  createPlugin(leo, systemClock);
})();
