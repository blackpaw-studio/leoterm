"use strict";
(() => {
  // src/clock.ts
  var systemClock = { now: () => Date.now() };

  // src/categories.ts
  var CATEGORIES = [
    { key: "system", label: "sys", tone: "accent1" },
    { key: "tools", label: "tools", tone: "accent2" },
    { key: "mcp", label: "mcp", tone: "accent3" },
    { key: "memory", label: "mem", tone: "accent4" },
    { key: "messages", label: "chat", tone: "accent5" }
  ];
  function otherTokens(context) {
    if (context.breakdown === void 0) return 0;
    const known = CATEGORIES.reduce((sum, c) => sum + (context.breakdown?.[c.key] ?? 0), 0);
    return Math.max(0, context.tokens - known);
  }
  function contextSegments(context) {
    const present2 = CATEGORIES.flatMap((c) => {
      const value = context.breakdown?.[c.key];
      return value === void 0 ? [] : [{ value, tone: c.tone }];
    });
    if (present2.length === 0) return [{ value: context.tokens, tone: "accent1" }];
    const other = otherTokens(context);
    return other > 0 ? [...present2, { value: other, tone: "secondary" }] : present2;
  }

  // src/format.ts
  var MINUTE_MS = 6e4;
  var HOUR_MS = 60 * MINUTE_MS;
  var DAY_MS = 24 * HOUR_MS;
  var trimZero = (s) => s.replace(/\.0$/, "");
  var scaled = (v) => v < 10 ? trimZero(v.toFixed(1)) : String(Math.round(v));
  function formatTokens(n) {
    if (n < 1e3) return String(Math.round(n));
    const k = scaled(n / 1e3);
    if (Number(k) < 1e3) return `${k}k`;
    return `${scaled(n / 1e6)}M`;
  }
  var formatPercent = (value, decimals) => `${value.toFixed(decimals)}%`;
  var formatMoney = (usd) => `$${usd.toFixed(2)}`;
  function formatReset(resetsAtISO, nowMs) {
    const target = Date.parse(resetsAtISO);
    if (Number.isNaN(target)) return void 0;
    const ms = target - nowMs;
    if (ms <= 0) return "now";
    if (ms < MINUTE_MS) return "<1m";
    if (ms < HOUR_MS) return `${Math.floor(ms / MINUTE_MS)}m`;
    if (ms < DAY_MS) return `${Math.floor(ms / HOUR_MS)}h ${Math.floor(ms % HOUR_MS / MINUTE_MS)}m`;
    return `${Math.floor(ms / DAY_MS)}d ${Math.floor(ms % DAY_MS / HOUR_MS)}h`;
  }
  function shortenPath(path) {
    const parts = path.split("/").filter((p) => p !== "");
    const head = path.startsWith("/") ? "/" : "";
    const abbreviate = (p) => p.slice(0, p.startsWith(".") ? 2 : 1);
    const last = parts.length - 1;
    return head + parts.map((p, i) => i === last || i === 0 && p === "~" ? p : abbreviate(p)).join("/");
  }
  var CLAUDE_ID = /^claude-([a-z]+)-(\d+)-(\d+)(?:-\d{8})?(\[1m\])?$/i;
  function formatModel(id) {
    const match = CLAUDE_ID.exec(id);
    if (!match) return id;
    const [, family, major, minor, longContext] = match;
    const name = family.charAt(0).toUpperCase() + family.slice(1).toLowerCase();
    return `${name} ${major}.${minor}${longContext ? " 1M" : ""}`;
  }

  // src/body.ts
  var GAP = "  ";
  var SEPARATOR = " \xB7 ";
  var LIMIT_LABELS = { five_hour: "session", seven_day: "weekly" };
  var LIMIT_ORDER = ["five_hour", "seven_day"];
  var line = (...runs) => ({ type: "Text", runs });
  var label = (text) => ({ text, tone: "secondary" });
  var gap = () => ({ text: GAP });
  var present = (runs) => runs.filter((r) => r !== void 0);
  function modelRow(usage) {
    if (usage.model === void 0 && usage.effort === void 0) return [];
    return [
      line(
        ...present([
          label("Model" + GAP),
          usage.model === void 0 ? void 0 : { text: formatModel(usage.model), tone: "accent1", weight: "semibold" },
          usage.model !== void 0 && usage.effort !== void 0 ? gap() : void 0,
          usage.effort === void 0 ? void 0 : label(`thinking ${usage.effort}`)
        ])
      )
    ];
  }
  function whereRow(usage, where) {
    const candidates = [
      where.workspace === void 0 ? [] : [{ text: shortenPath(where.workspace), mono: true }],
      where.branch === void 0 ? [] : [{ text: where.branch, tone: "accent3" }],
      usage.git === void 0 ? [] : [
        { text: "(" },
        { text: `+${usage.git.added}`, tone: "success", mono: true },
        { text: "," },
        { text: `\u2212${usage.git.removed}`, tone: "failure", mono: true },
        { text: ")" }
      ]
    ];
    const parts = candidates.filter((p) => p.length > 0);
    if (parts.length === 0) return [];
    return [line(label("Where" + GAP), ...parts.flatMap((p, i) => i === 0 ? p : [gap(), ...p]))];
  }
  function legend(context) {
    const items = [
      ...CATEGORIES.flatMap((c) => {
        const tokens = context.breakdown?.[c.key];
        return tokens === void 0 ? [] : [{ text: `${c.label} ${formatTokens(tokens)}`, tone: c.tone }];
      }),
      ...otherTokens(context) > 0 ? [{ text: `other ${formatTokens(otherTokens(context))}`, tone: "secondary" }] : [],
      ...context.tokens <= context.window ? [{ text: `free ${formatTokens(context.window - context.tokens)}`, tone: "secondary" }] : [],
      ...context.compactAt === void 0 ? [] : [{ text: `compacts at ${Math.round(context.compactAt * 100)}%`, tone: "secondary" }]
    ];
    if (items.length === 0) return void 0;
    return line(...items.flatMap((r, i) => i === 0 ? [r] : [label(SEPARATOR), r]));
  }
  function contextRows(context) {
    if (context === void 0) return [];
    const percent = formatPercent(context.percent, 1);
    const rows = [line(label("Context" + GAP), { text: percent, mono: true })];
    if (context.window > 0) {
      const bar = {
        type: "Meter",
        segments: contextSegments(context),
        max: context.window,
        label: percent,
        help: `${formatTokens(context.tokens)} / ${formatTokens(context.window)} tokens`
      };
      rows.push(bar);
    }
    const key = legend(context);
    return key === void 0 ? rows : [...rows, key];
  }
  var limitRank = (kind) => {
    const i = LIMIT_ORDER.indexOf(kind);
    return i === -1 ? LIMIT_ORDER.length : i;
  };
  function limitLine(limit, nowMs) {
    const reset = formatReset(limit.resetsAt, nowMs);
    return line(
      ...present([
        { text: LIMIT_LABELS[limit.kind] ?? limit.kind },
        { text: " " + formatPercent(limit.percentUsed, 1), mono: true },
        reset === void 0 ? void 0 : label(` resets ${reset}`)
      ])
    );
  }
  function limitRows(usage, nowMs) {
    const limits = [...usage.rateLimits ?? []].sort((a, b) => limitRank(a.kind) - limitRank(b.kind));
    const cost = usage.session === void 0 ? [] : [line(label("cost "), { text: formatMoney(usage.session.costUsd), mono: true })];
    const rows = [...limits.map((l) => limitLine(l, nowMs)), ...cost];
    return rows.length === 0 ? [] : [line(label("Limits")), ...rows];
  }
  var emptyState = (title, message) => ({ type: "EmptyState", title, ...message === void 0 ? {} : { message } });
  function buildBody(usage, where, nowMs) {
    if (usage === null) return [emptyState("No usage data yet", "This agent has not reported usage.")];
    if (Object.keys(usage).length === 0) return [emptyState("No usage data", "This agent's harness does not report usage.")];
    const rows = [
      ...modelRow(usage),
      ...whereRow(usage, where),
      ...contextRows(usage.context),
      ...limitRows(usage, nowMs)
    ];
    return rows.length === 0 ? [emptyState("No usage data yet")] : rows;
  }

  // src/summary.ts
  var SEPARATOR2 = " \xB7 ";
  var plain = (text) => ({ type: "Text", runs: [{ text, tone: "secondary" }] });
  var modelNode = (model) => ({ type: "Text", runs: [{ text: formatModel(model), tone: "accent1", weight: "semibold" }] });
  function meterNode(context) {
    if (!(context.window > 0)) return void 0;
    return {
      type: "Meter",
      segments: contextSegments(context),
      max: context.window,
      help: `${formatTokens(context.tokens)} / ${formatTokens(context.window)} tokens`
    };
  }
  function figuresNode(usage) {
    const fiveHour = usage.rateLimits?.find((l) => l.kind === "five_hour");
    const parts = [
      usage.context && formatPercent(usage.context.percent, 0),
      fiveHour && `5h ${formatPercent(fiveHour.percentUsed, 0)}`,
      usage.session && formatMoney(usage.session.costUsd)
    ].filter((p) => typeof p === "string");
    return parts.length === 0 ? void 0 : { type: "Text", runs: [{ text: parts.join(SEPARATOR2), mono: true }] };
  }
  function buildSummary(usage) {
    if (usage === null) return plain("\u2014");
    if (Object.keys(usage).length === 0) return plain("No usage data");
    const nodes = [
      usage.model === void 0 ? void 0 : modelNode(usage.model),
      usage.context && meterNode(usage.context),
      figuresNode(usage)
    ].filter((n) => n !== void 0);
    return nodes.length === 0 ? plain("\u2014") : nodes;
  }

  // src/plugin.ts
  var PANE_ID = "status";
  var TICK_SEC = 60;
  var keyOf = (a) => `${a.machine}/${a.name}`;
  var isStatusPane = (slot) => slot.kind === "pane" && slot.id === PANE_ID;
  var errorMessage = (e) => e instanceof Error ? e.message : String(e);
  function createPlugin(leo2, clock) {
    let states = /* @__PURE__ */ new Map();
    let tick;
    const put = (state) => {
      states = new Map(states).set(keyOf(state.agent), state);
    };
    const paint = (state) => {
      const { summary, body } = state.slots;
      if (state.usage === void 0) return;
      if (state.usage === "denied") {
        if (summary) leo2.render(summary, { type: "Text", runs: [{ text: "Usage unavailable", tone: "secondary" }] });
        if (body) leo2.render(body, { type: "EmptyState", title: "Usage unavailable" });
        return;
      }
      if (summary) leo2.render(summary, buildSummary(state.usage));
      if (body) leo2.render(body, buildBody(state.usage, state.where, clock.now()));
    };
    const armTick = () => {
      tick?.cancel();
      tick = leo2.after(TICK_SEC, () => {
        states.forEach(paint);
        armTick();
      });
    };
    const readWhere = async (agent) => {
      try {
        const match = (await leo2.agents.list()).find((a) => a.machine === agent.machine && a.name === agent.name);
        return { workspace: match?.workspace, branch: match?.branch ?? void 0 };
      } catch (e) {
        leo2.log("warn", `agents.list failed: ${errorMessage(e)}`);
        return {};
      }
    };
    const readUsage = async (agent) => {
      try {
        return await leo2.agents.usage(agent);
      } catch (e) {
        leo2.log("error", `agents.usage failed: ${errorMessage(e)}`);
        return "denied";
      }
    };
    const refresh = async (agent) => {
      const current = states.get(keyOf(agent));
      if (!current) return;
      const generation = current.generation + 1;
      put({ ...current, generation });
      const [usage, where] = await Promise.all([readUsage(agent), readWhere(agent)]);
      const latest = states.get(keyOf(agent));
      if (!latest || latest.generation !== generation) return;
      const next = { ...latest, usage, where };
      put(next);
      paint(next);
      armTick();
    };
    leo2.on("viewOpened", async (agent, slot) => {
      if (!isStatusPane(slot)) return;
      const existing = states.get(keyOf(agent));
      put({
        agent,
        slots: { ...existing?.slots, [slot.part]: slot },
        usage: existing?.usage,
        where: existing?.where ?? {},
        generation: existing?.generation ?? 0
      });
      await refresh(agent);
    });
    leo2.on("usageChanged", async (agent) => {
      await refresh(agent);
    });
  }

  // src/main.ts
  createPlugin(leo, systemClock);
})();
