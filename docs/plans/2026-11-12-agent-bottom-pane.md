# Plan: Agent Bottom Pane + Status Plugin

**Specs:** `docs/superpowers/specs/2026-11-12-agent-bottom-pane.md` and `docs/superpowers/specs/2026-11-12-status-plugin.md`. If this plan and a spec disagree, the spec wins. **Base:** `2026-11-10-plugin-platform.md` and its plan.

**Platform call: Mac only.** Plugins only exist on the Mac in v1. The new LeoKit usage decoding is platform-neutral, so the iOS app can reuse it later. Panes on iOS are covered by the existing iOS plugin-host backlog item (platform 6.4). Add a one-line idea there for "agent pane on iOS".

**Commands**
- LeoKit tests: `swift test --package-path Packages/LeoKit --filter <Suite>`
- App build, from `macos/`, as a background job: `heavy xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO -packageAuthorizationProvider netrc`
- App tests: `xcodebuild test-without-building … -only-testing:GhosttyTests/<Suite>`
- Plugin: `cd plugins/status && npm ci && npm run typecheck && npm test && npm run build`

Each step is its own commit. Every step starts from a failing test unless it says "TDD exception".

## Step 0 is the gate: freeze the wire contract

Step 0 runs first, on its own. It fixes the JSON names that lanes A–D all depend on.

- **Files:** `plugins/sdk/leo.d.ts` and `plugins/sdk/README.md`. TDD exception (types and docs only).
- **Pane slot:** `{kind:"pane", id, part:"summary"|"body", agent:{machine,name}}`. Plugins get it from `viewOpened(agent, slot)`, the existing opening event, which the spec's Status plugin already listens to.
- **Text:** `Text {runs:[{text, tone?, weight?, mono?}]}`.
- **Meter:** `Meter {segments:[{value,tone}], max, label?, help?}`.
- **Tone:** `"secondary"|"accent1".."accent6"|"success"|"warning"|"failure"`.
- **Usage snapshot:** `UsageSnapshot {model?, effort?, context?{tokens,window,percent,breakdown?{system,tools,mcp,memory,messages},compactAt?}, session?{tokens,costUsd}, rateLimits?[{kind,percentUsed,resetsAt}], git?{added,removed}}`. Absent keys are omitted, not sent as null.
- **Agents:**
  - `leo.agents.usage(agent: AgentRef) → Promise<UsageSnapshot|null>`
  - `on("usageChanged", (agent: AgentRef) => …)`
  - `AgentSnapshot.model?`
- **Permission:** `agents` gains `"usage"`.
- **Verify:** `tsc --noEmit` over `plugins/github`, which also compiles `leo.d.ts`.
- **Spec deviations Q1 and Q2 must be approved before step 0 lands.**

## Steps

### LeoKit platform

**1. Manifest `panes` and the `usage` verb.**
- Files: `Plugins/LeoPluginManifest.swift` (add `LeoPluginPaneContribution{id,title,sfSymbol?}`, `contributes.panes`, and `LeoPluginAgentVerb.usage`), `LeoPluginManifestValidator.swift` (at most 1 pane, id shape, SF Symbol allowlist), and the permission rows in `Install/LeoPluginApproval.swift`.
- Failing test: `LeoPluginManifestTests`. It covers a pane that decodes, two panes refused, an unknown pane key refused, and an unknown verb whose error message lists usage. `LeoPluginApprovalReviewTests` checks that an update adding `usage` shows up as a permission increase.
- Parallel: yes.

**2. Pane slot ID and routing.**
- Files: `LeoPluginSlotID.swift` (`.pane(id:part:agent:)`, key, codec), `Manager/LeoPluginBridgeRouter.swift` and `LeoPluginManager+Events.swift` (`declares` and `openingEvent` map `.pane` to `.viewOpened(agent, slot)`).
- Failing tests: `LeoPluginWireTests` (round-trip), `LeoPluginBridgeRouterTests` (rendering an undeclared pane is refused), `LeoPluginManagerTests` (opening a pane sends `viewOpened`).
- Depends on 1.

**3. Text and Meter nodes.**
- Files: `LeoPluginNode.swift` (`.text`, `.meter`, `LeoPluginTone`, limits: 200 characters per run, 20 runs, 8 segments, help ≤80 characters, finite non-negative values with `max > 0`; node count includes each new node), `LeoPluginTreeDiff.swift`.
- Failing tests: `LeoPluginNodeDecodingTests` (limits, unknown tone refused, raw hex refused) and `LeoPluginTreeDiffTests`.
- Parallel: with 1 and 2.

**4. Summary allowlist.**
- Files: `LeoPluginBridgeRouter.swift`. A render to a `.pane(part:.summary)` slot containing anything other than Text, Meter or Accessory puts the slot in `.error`. The app draws that as "!".
- Failing test: `LeoPluginBridgeRouterTests`.
- Depends on 2 and 3.

**5. Optional telemetry decoding.**
- Files: `Observe/LeoAgentUsage.swift`. Add `effort`, `context.breakdown`, `context.compact_at` (0–1), `rate_limits[{kind,percent_used,resets_at}]` (an unknown `kind` drops that entry only) and `git{added,removed}`. All are decoded with `LeoLenient`. Add `model` to `LeoObservedAgent` in `Observe/LeoActivityClient.swift` and to the agent row in `LeoModels.swift`, and pass it through the sidebar row.
- Failing test: a new `LeoAgentUsageTelemetryTests` with three fixtures: today's payload (unchanged), the full telemetry payload, and malformed fields. Each malformed field reads as absent and never fails the usage it rides in.
- Parallel: yes.

**6. Usage snapshot mapper.**
- Files: a new `Plugins/Services/LeoPluginUsageSnapshot.swift`. It maps usage to camelCase JSON, omits absent keys, and is gated by `engine.check(agent: .usage)`. It also fixes the `session` mapping (see risk R6).
- Failing test: a new `LeoPluginUsageSnapshotTests` covering denial without `usage`, absent stays absent, and costs that are not plausible are dropped.
- Depends on 1 and 5.

**7. Bridge `agents.usage` and `model` in `agents.list`.**
- Files: `LeoPluginBridge.swift` (`.agentsUsage(id, agent)`), `Runtime/LeoPluginJSPrelude.swift`, `LeoPluginAgentSource` (add `usage(for: LeoPluginAgentRef) -> (model: String?, usage: LeoAgentUsage?)?`), `Services/LeoPluginAgentsSnapshot.swift` (include `model` only when `usage` is granted).
- Failing tests: `LeoPluginBridgeTests`, `LeoPluginJSRuntimeTests` (the prelude round-trips), `LeoPluginAgentsSnapshotTests` (no `model` without `usage`).
- Depends on 6.

**8. `usageChanged` event and coalescer.**
- Files: a new `Plugins/Services/LeoPluginUsageCoalescer.swift`, `LeoPluginBridge.swift` (`.usageChanged(agent)`), `LeoPluginManager+Events.swift` (`usageDidChange(agent:)`), `Slots/LeoPluginSlotVisibility.swift` (add `isPaneVisible(plugin:)`).
- Coalescing: the first change for an agent fires at once; further changes within 1 s collapse into one trailing fire. The event goes only to plugins that hold `usage` and have a pane slot visible.
- Failing tests: a new `LeoPluginUsageCoalescerTests` with an injected clock and scheduler, and `LeoPluginManagerTests` checking that nothing is delivered while the pane is hidden.
- Depends on 2 and 7.

### App

**9. Text and Meter renderers.**
- Files: new `Render/LeoPluginTextView.swift` and `Render/LeoPluginMeterView.swift`, `LeoPluginNodeView.swift`, and the tone→colour map in `LeoPluginRenderSupport.swift`. All tone colours are dynamic, so they follow light and dark mode.
- Failing tests:
  - a new `LeoPluginMeterGeometryTests`, testing a pure function: segment widths clamp to `max`, the overflow is cut, and the summary bar is 56×5;
  - `LeoPluginToneTests`: every tone maps to a colour.
- Depends on 3.

**10. Pane state machine.**
- Files: a new `macos/Sources/Features/Leo/AgentPane/LeoAgentPaneState.swift` (pure). It handles tapping a tab, tapping the selected tab, the chevron, the menu toggle, and clamping the height (min 120, max half the column, default 184). Persistence goes through an injected `UserDefaults` suite. Concurrent test runs share the debug defaults, so tests must not use `.standard`.
- Failing test: a new `LeoAgentPaneStateTests`.
- Parallel: yes.

**11. Tab overflow layout.**
- Files: a new `AgentPane/LeoAgentPaneTabLayout.swift`, a pure `fit(tabs, selected, width)` that returns, for each tab, full, title only or "+N". It follows the `LeoPluginAccessoryLayout` pattern.
- Failing test: `LeoAgentPaneTabLayoutTests`. When summaries don't fit, the selected tab keeps its summary and the others drop to titles. When titles don't fit, the extra tabs collapse into "+N".
- Parallel: yes.

**12. Tab list and hiding.**
- Files: `Registry/LeoPluginRegistry.swift` (`hiddenPanes`, `setPane(hidden:)`) and a new `AgentPane/LeoAgentPaneTabs.swift`. Tabs come from enabled plugins with a pane, first-party first, then in install order, without hidden ones. A crashed or disabled plugin keeps its tab with a warning glyph.
- Failing tests: `LeoPluginRegistryTests` and `LeoAgentPaneTabsTests`.
- Depends on 1.

**13. Pane view and split integration.**
- Files:
  - new `AgentPane/LeoAgentPaneView.swift` (tab bar and body; the body reuses `LeoPluginSlotHostView`);
  - `Sidebar/LeoSplitViewRepresentable.swift`: the detail column becomes a nested vertical split of terminal/chat over the pane. Holding priorities stay in 250–260, with the pane higher so it keeps its height when the window resizes. Collapsed, min and max thickness are both 30. No contributing plugin means no pane item at all;
  - `MainMenu.xib` and `TerminalController+Leo.swift`: View → "Toggle Agent Pane".
- Visibility: summary keys are reported while the pane is shown. The body key is reported only while that tab is expanded, using `LeoPluginVisibilityReporter` with `isActive`.
- Failing tests: `LeoPluginVisibilityReporterTests` (summary/body visibility per state) and `LeoAgentPaneSplitTests` (priorities in band, collapsed thickness).
- Verify: launch the debug app (exit code 124 means alive) and take screenshots with Peekaboo.
- Depends on 2 and 9–12.

**14. Settings → Plugins "Show agent pane" toggle.**
- Failing test: `LeoPluginsSettingsModelTests`.
- Depends on 12.

**15. App usage source.**
- Files: `Manager/LeoPluginAppSources.swift`. `usage(for:)` reads the sidebar rows' `metadata.usage` and `model`. Diffing each row's usage calls `manager.usageDidChange`. It fires after the rows refresh, not on the raw SSE event, so `agents.usage` never reads stale data.
- Failing test: `LeoPluginAppAdaptersTests`.
- Depends on 7 and 8.

**16. Fixture plugin and host integration.**
- Files: a new `macos/Tests/Fixtures/Plugins/pane-demo/`, which renders a summary and body with every tone and Meter edge, plus `LeoPluginHostIntegrationTests` (`agents.usage` and `usageChanged` round-trip in the real JavaScriptCore host).
- Depends on 7, 8 and 13.
- **UI check:** collapsed, expanded and overflow states, in light and dark mode, at native pixels. Audit every image before posting it to Evan.

### Status plugin (`plugins/status`)

**17. Scaffold.**
- Copy the GitHub plugin's toolchain: pinned Node 22, esbuild 0.25.10, TypeScript 5.9.3, vitest 3.2.4 (`env.TZ` set).
- Manifest goes only in `macos/Bundled/Plugins/studio.blackpaw.status/leo-plugin.json`: permissions `agents:[read,usage]`, pane `status` ("Status", `gauge`). Bundling into the app is automatic through `leo-bundle-plugins.sh`.
- Add the `git diff --exit-code` line to `.github/workflows/leo-ci.yml`, and add `test/stubLeo.ts` with `usage` and `usageChanged`.
- TDD exception (config).
- Depends on 0.

**18. `src/format.ts`.**
- Tokens (`3.1k`, `154k`, `1.2M`), percentages (1 decimal place in the body, none in the summary), money (`$35.36`), relative resets (`3h 50m`, `4d 2h`) and path shortening.
- Failing test: `format.test.ts`, with boundaries at 999, 1000, 999 999 and 1 000 000.
- Parallel: yes.

**19. `src/summary.ts`.**
- Model in `accent1`, Meter (breakdown segments or one total segment, `help` = token count), context %, 5h % only when present, cost only when present, and the `—` / `No usage data` empty states.
- Failing test: `summary.test.ts`, one case per present/absent combination.
- Depends on 18.

**20. `src/body.ts`.**
- Four rows, each hidden per missing field, never shown as 0. The legend shows free tokens and `compacts at`.
- Failing test: `body.test.ts`.
- Depends on 18. The "Where" row's path is blocked on Q3.

**21. `src/plugin.ts`.**
- Remembers the pane slots per agent from `viewOpened`. Re-renders on `usageChanged` for an agent it holds slots for. Ticks the countdown with `after(60)`. Takes the clock by dependency injection.
- Failing test: `plugin.test.ts`, with fake timers and a stub that records renders per slot.
- Depends on 19 and 20.

**22. Build and check.**
- Byte-deterministic bundle, plus `manifest.test.ts` (the permissions are exactly these).
- Depends on 21.

**23. End-to-end integration gate.**
- Use the isolated daemon recipe and a stub-claude scratch agent. Never send keystrokes to real agents.
- Check collapsed and expanded, light and dark, at native pixels. Use the attention-fixture usage overlay to show the telemetry fields before the daemon ships them.
- Then run the full LeoKit and app suites under `heavy`.

## Lanes (at most 4 implementers at once, after step 0)

| Lane | Steps | Notes |
|---|---|---|
| A: LeoKit surface | 1 → 2 → 3 → 4 | Owns the `Plugins/` model files. |
| B: LeoKit usage | 5 → 6 → 7 → 8 | 6 waits for A's step 1 (the verb). Rebase onto A. Touches `LeoPluginBridge.swift`, which A also touches; order the commits A2 before B7. |
| C: App | 10, 11 (immediately) → 9 (after A3) → 12 (after A1) → 13 → 14 → 15 (after B8) → 16 | Swift work goes to Claude `implement`, not Codex, because the Codex sandbox can't run xcodebuild. |
| D: Status plugin | 17 → 18 → 19/20 → 21 → 22 | Fully independent after step 0. Step 23 runs when all lanes are done. |

**Review gate:**
- Lanes A and C: `review`.
- Lane B: `review.security`. It changes the permission engine, the bridge and data exposure across the sandbox boundary.
- Lane D: `review`.
- Severity bar: P0/P1, plus anything a real plugin or user can hit.

## Risks

- **R1, split view.** Legacy split-view delegate sizing methods crash the app at launch, and a green test suite can't see it. A holding priority of 750 freezes the pane. `setPosition` does nothing before the view is in a window. So: apply the remembered height after the window attaches, and run a launch check (exit code 124 = alive) in step 13.
- **R2, telemetry may never arrive** from some harnesses. Every field is optional, step 5's fixtures cover the absent case, and the UI hides missing fields instead of showing 0.
- **R3, `model` is not decoded today.** The app's agent and observed-agent models have no `model` field. The telemetry request only *asks* the daemon to confirm it is in the state payload. Until it is, the summary leads with the meter.
- **R4, usage is fetched per row** through metadata refresh, so `usageChanged` lags the SSE event by one refresh. Accepted: it is correct data, and the delay is at most one refresh.
- **R5, `LeoPluginBridge.swift` and `LeoPluginManager+Events.swift`** get edits from lanes A and B. Serialize those commits.
- **R6, usage snapshot has no "absent" session.** `LeoAgentUsage` requires `session` and zero-fills a missing cost. Step 6 must map a missing cost to absent, not `costUsd: 0`. Otherwise "Cost: shown only when present" breaks.

## Open questions (marked where the spec doesn't settle them)

- **Q1 (spec deviation):** The spec shows `leo.render("<paneId>.summary", tree)`, but the platform hands plugins slot objects from events, and the pane follows the selected agent. A slot that isn't tied to an agent would flash the previous agent's data. **Recommendation:** a per-agent `pane` slot object delivered via `viewOpened`.
- **Q2 (spec deviation):** `usage(agentName)` and `usageChanged(agentName)` are ambiguous across Machines. **Recommendation:** `AgentRef {machine,name}`, matching `viewOpened`.
- **Q3 (not settled; blocks the path in step 20):** The Status plugin's "Where" row needs the workspace path, but the base spec forbids exposing paths to plugins (`LeoPluginAgentsSnapshot` has "no path field"), and the pane spec's bridge additions don't include one. Options:
  - (a) add a home-relative `workspace` behind `agents:usage`, which needs a security review;
  - (b) the app pre-shortens it to `~/.l/a/leoterm`;
  - (c) show repo and branch instead.
- **Q4 (not settled):** "No usage data" vs `—`. The bridge has no signal for "this harness never reports usage". **Proposal:** `usage()` returns `null` for "no data yet" and `{}` for "harness doesn't report", based on the daemon's `agent_usage` feature and the template's harness. This needs a decision.
- **Q5 (not settled):** The colours for `accent1`…`accent6` and the single total-segment tone. **Proposal:** system dynamic colours that match rich-statusline's order. Evan approves at the step 16 screenshots.
- **Q6 (not settled):** The spec names the GitHub plugin as a pane consumer, and the Status spec says GitHub's tab "covers the PR", but no GitHub pane content is specified. **Recommendation:** leave it out of this plan as a follow-up spec.
- **Q7 (minor; plan decision):** `usageChanged` goes only to plugins with a visible pane, for any agent the plugin holds slots for, not every agent.
- **Q8 (minor; plan decision):** The coalescer fires the first change at once and the rest as one trailing fire per 1 s window.

## Orchestrator decisions (2026-11-12)

- **Q1 accepted:** panes are per-agent slot objects delivered through `viewOpened`. The spec is updated.
- **Q2 accepted:** `AgentRef {machine, name}` everywhere.
- **Q3 (Evan):** the full home-relative `workspace` (absolute when it is outside home) goes on `agents.list()` entries behind `agents:usage`. The plugin shortens it itself. Lane B must send this to `review.security`.
- **Q4 accepted:** `usage()` returns `null` for "no data yet" and `{}` for "harness doesn't report usage".
- **Q5:** tones use system dynamic colours in rich-statusline's order. Evan approves them at the step-16 screenshots.
- **Q6:** the GitHub pane is a follow-up spec, not part of this plan.
- **Q7, Q8:** accepted as written.
- **R3 resolved:** the daemon has `model` on Agent (configured) and is adding `usage.model` (observed), per the `leo` agent on 2026-11-12. Step 5 decodes both, and the snapshot's `model` prefers the observed value.
- **Daemon status:** the `leo` agent is building PR A (Claude telemetry plus git), then PR B (Codex). Wire names are `usage.{model, effort, context.breakdown, context.compact_at, rate_limits[{kind, percent_used, resets_at}], git{added, removed}}`.
