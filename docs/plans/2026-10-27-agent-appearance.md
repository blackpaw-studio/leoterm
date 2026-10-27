# Agent Appearance: implementation plan

Spec (source of truth): `docs/superpowers/specs/2026-10-27-agent-appearance.md`. Mockups are for look only.
Branches: leoterm `feat/agent-appearance` (this worktree). leo: a new worktree `~/.leo/agents/.worktrees/leo/agent-appearance` off `origin/main` on branch `feat/agent-appearance`. Do not touch the `leo` agent's checkout. The `leo` agent reviews and merges the daemon PR; we never merge it ourselves.
**Platform call: both.** The daemon owns the data and the resolution. LeoKit owns the wire model, the palette names, the resolver (used only for the Settings preview), the emoji catalog and the API client. Each app keeps only its rendering and editor UI. Differences between the apps: Mac uses a context menu, a popover and a Settings pane, and is SwiftUI-capable. iOS uses a long-press sheet and is UIKit + TCA only. The iOS rules editor is deferred (step I5).

**Commands** (run heavy ones through `heavy`, as background Bash jobs)
- `GO(x)`: `cd <leo worktree> && go test -race ./internal/<pkg>/... -run '<x>'`. Gate: `heavy go test -race ./...` and `heavy make lint`.
- `LK(x)`: `cd Packages/LeoKit && DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer swift test --filter '<x>'`
- `MB`: from `macos/`: `heavy env DEVELOPER_DIR=…26.3… xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- `MT(x)`: `timeout 600 xcodebuild test-without-building … -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<x>`
- `F(x)`: `cd ios/LeoFeatures && DEVELOPER_DIR=/Applications/Xcode-26.5.0.app/Contents/Developer swift test --filter '<x>'`
- `IB` / `IT(T/S)`: `cd ios && xcodegen generate && heavy env DEVELOPER_DIR=…26.5… xcodebuild build-for-testing -project Leo.xcodeproj -scheme Leo -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath build/DD-ios CODE_SIGNING_ALLOWED=NO`. `IT` is the same build with `test-without-building -only-testing:<T>/<S>`.
- Every step that runs xcodebuild goes to a Claude-backed `implement` role (Codex cannot write the SwiftPM cache).

## 0. Decision (resolved: A, Evan 2026-10-27)

**D1. Where manual appearance lives.** The spec says manual values go "on the agent's own config entry" in `leo.yaml`. Agents have no entry there. Spawned agents are records in `state/agents.json` (`internal/agentstore/store.go` `Record`), and that is also where the per-agent environments override lives (`Record.Environments`). Only persistent-task agents have a `tasks.<name>` block in `leo.yaml`.
- **A (recommended): `agentstore.Record.Appearance`.**
  - It sits next to the environments override, which is its exact analog.
  - Rename carries it (`agentstore.Rename`) and delete removes it.
  - No `leo.yaml` rewrite on every click. Each rewrite strips comments (config-api.md "Revisions") and bumps the revision, which 409s any Settings pane left open.
  - Cost: it is not hand-editable in `leo.yaml`, and deleting the agent drops it.
- **B: a top-level `agent_appearance: {<name>: {emoji, color}}` map in `leo.yaml`.**
  - It survives delete and re-create and can be hand-edited.
  - Every edit goes through `config.Writer` + Save + the revision, so it pays the costs listed under A.
  - Rename and delete must also rewrite `leo.yaml`.

The rules stay in `leo.yaml` (`appearance_rules`) either way. **The config write path already exists**, so the spec's other blocking condition does not apply. The pieces are: `config.Writer` (the in-process lock), `config.LoadWithRevision` → mutate → `config.Save` (atomic, 0600), the `ETag`/`If-Match` revision, and `ConfigService` reload. Socket and `/api/v1` both serve it, as `docs/configuration/config-api.md` describes. The rest of this plan assumes **A**. If Evan picks B, steps D3 and D4 change and nothing else does.

## Wire contract (D0 commits it first, as golden fixtures)

- **Agent wire:** `/state` agent objects and the `agent` on `agent_spawned` gain `"appearance": {"emoji"?, "color"?, "emoji_source"?, "color_source"?}`. The key is omitted when both values are unset. A source is `"manual"` or `"rule:<i>"` (0-based).
- **New event `agent_appearance_changed`:** `{seq, at, agent, appearance: {…} | null}`, where `null` means nothing is set. The daemon publishes it after a manual set, a rules PUT, a config reload or config-API write, a SetEnvironments, a SwitchTemplate and a rename.
  - Old apps decode an unknown event type as `.other(seq:type:)` (`LeoActivityClient.swift:355`), so they keep their sequence.
  - This avoids adding a field to `agentStateChanged`, which would touch 37 pattern-match sites.
- **Feature flag:** `FeatureAgentAppearance = "agent_appearance"`, set in `internal/observe/event.go`. It feeds both the hello features and `/version` capabilities (`Capabilities()` is `observe.Features()`).
- **`GET /appearance/rules`** (socket) and **`GET /api/v1/appearance/rules`** (operator or paired device) return the envelope `data: {revision, rules: [{when: {field, op, value}, color?, emoji?}], errors: [{index, reason}]}`.
- **`PUT` on the same path** sends body `{rules}` with `If-Match` required, using the config API's 428 and 409 semantics. The list is replaced atomically.
  - It answers 400 `invalid_appearance_rule` with `data: {index, reason}` (the spec says 400, not the config API's 422).
  - On 200 it returns `{revision, rules, errors: []}`.
- **`PUT /agents/{name}/appearance`** (socket) and **`/api/v1/agents/{name}/appearance`** (`requireOperatorToken`) take body `{emoji?, color?}`. A present value sets, `null` clears, and an absent key is left unchanged.
  - Answers: 200 with the resolved appearance, 404 for an unknown agent, 400 `invalid_appearance` with the reason.
  - "Reset to rules" sends `{emoji: null, color: null}`.

## Phase D: daemon PR (leo repo)

**D0. Contract fixtures (implement).**
- Add `internal/observe/testdata/wire/appearance-{agent,agent-partial,event,event-null,rules,rule-error}.json`.
- Add a shared resolution-vector file, `internal/agent/testdata/appearance-vectors.json`, with cases of `{agent facts, manual, rules} → expected`. Copy it byte-for-byte to `Packages/LeoKit/Tests/LeoKitTests/Fixtures/`. From then on, LeoKit work (L1–L2) can run in parallel with D1–D5.

**D1. Config model and validation (implement).**
- New `internal/config/appearance.go`:
  - The palette constant.
  - `AppearanceRule{When{Field,Op,Value}, Color, Emoji}`.
  - `validateAppearanceRules()`, called from `Config.Validate` next to `validateEnvironments` (same error path: `leo validate` and the config API).
  - A lenient `UnmarshalYAML`: a structurally wrong rule (a map where a string belongs, say) is kept as a raw `yaml.Node`, marked invalid, and re-marshalled unchanged. It never fails `Load`, because a `Load` error would block the daemon's boot or reload.
- `Config.AppearanceRules` (`yaml:"appearance_rules,omitempty"`) in `config.go`.
- Rules: fields `name|environments|template|harness`, ops `is|contains|starts_with|glob`, a non-empty value, at least one of color or emoji, color from the palette, emoji a single grapheme of at most 64 bytes.
  - Grapheme checks use `github.com/rivo/uniseg`, promoted from indirect to direct.
  - Glob is restricted to `*` and `?` (see Q3).
- Failing tests first:
  - `TestValidateAppearanceRules` (table: every rejection reason).
  - `TestAppearanceRulesLenientLoad` (a malformed rule loads and round-trips through `Save` byte-stable).
  - `TestSaveSplitKeepsAppearanceRules`.
- Verify: `GO(config) -run 'Appearance'`.

**D2. Resolver (implement).**
- New `internal/agent/appearance.go`, `ResolveAppearance(rules, facts{Name, Environments(effective), Template, Harness}, manual) *observe.Appearance`.
  - Harness goes through `normalizeHarness`, so empty means `claude`.
  - Color and emoji resolve independently: the manual value wins, then the first rule from the top that sets the field, then unset. Invalid rules are skipped.
  - For `environments`, `is` and `contains` test membership; `starts_with` and `glob` match if any element matches (Q5).
  - Matching is case-sensitive (Q4).
- Add `observe.Appearance` and `Agent.Appearance *Appearance` (`json:"appearance,omitempty"`) in `internal/observe/snapshot.go`.
- Failing test first: `TestResolveAppearance`, driven by `appearance-vectors.json`. It covers manual over rule, first match wins, independent fields, environments membership, glob, starts_with, harness default, and an invalid rule being skipped.
- Verify: `GO(agent) -run Appearance`.

**D3. Persistence (implement).**
- Add `agentstore.Record.Appearance *Appearance` (`json:"appearance,omitempty"`).
- **`Save` keeps the stored `Appearance`** the way it keeps `AttentionToken` (`store.go:240`). Respawn paths build fresh records and would otherwise wipe it.
- New `agentstore.SetAppearance(home, name, patch)` via `Update`.
- Failing tests first: `TestSavePreservesAppearance`, `TestSetAppearancePatch` (set, null clears, absent unchanged), `TestRenameCarriesAppearance`.

**D4. Wire, events and republish (implement.hard).**
- Call the resolver at every place that builds `observe.Agent`:
  - `service/observe.go:197` (`spawnedAgentView`)
  - `web/handlers_observe.go:528` (the snapshot)
  - `agent/manager.go:2127` (rename)
  - the socket `/state` path
- Add `EventAgentAppearanceChanged` and `FeatureAgentAppearance`.
- Add `Manager.RepublishAppearance()`, which publishes for every known agent with no diff cache (agent counts are small). Call it after a rules PUT, after `Server.ReloadConfig`, after any `ConfigService` write that reloads, and after `SetEnvironments` and `SwitchTemplate`.
- Failing tests first:
  - `TestSnapshotAppearanceOmittedWhenUnset`
  - `TestSnapshotAppearanceSources`
  - `TestSpawnedEventCarriesAppearance`
  - `TestSetEnvironmentsRepublishesAppearance`
  - `TestFeaturesIncludeAgentAppearance`
  - golden comparisons against the D0 fixtures
- Verify: `GO(observe)`, `GO(service) -run Appearance`, `GO(agent) -run Appearance`.

**D5. Routes (implement.hard).**
- New `internal/web/handlers_appearance.go` on `ConfigService`, holding the rules GET and PUT under the `Writer` lock with a revision check, then Save, reload and `RepublishAppearance`. Register it on the socket (bare) and the web side (`/api/v1`, operator wrap) the way `RegisterConfigRoutes` does.
- Agent PUT: one core (`Manager.SetAppearance`) with a socket handler in `internal/daemon/handlers_agents.go` and a web handler in `internal/web/handlers_agents.go`.
- Failing tests first:
  - `TestAppearanceRulesRoutes`: 200 persisted to `leo.yaml`, 400 with index and reason, 428, 409, an event published, and an agent token answered 403.
  - `TestAgentAppearanceRoute`: set, null, absent, 404, 400, persisted to `agents.json`, event.
  - A socket↔web parity test, extending `config_api_parity_test.go`.
- Verify: `GO(web) -run Appearance`, `GO(daemon) -run Appearance`.

**D6. Docs and ship (implement).**
- Docs: new `docs/configuration/appearance.md`, a section in `config-api.md`, and a CHANGELOG entry.
- Run the gate: `heavy go test -race ./...` and `heavy make lint`.
- Open the PR and `leo_send_message` the `leo` agent to review and merge it. Route the agent's requested changes back to the same implementer through `leo_send_dispatch`.
- Note the leo release that carries `agent_appearance`.

## Phase L: LeoKit (starts after D0)

**L1. Wire (implement).**
- New `Packages/LeoKit/Sources/LeoKit/Observe/LeoAppearanceWire.swift`, modelled on `LeoEnvironmentsWire`. It is the only place that knows the keys and routes.
- Types: `LeoAgentAppearance{emoji, color, emojiSource, colorSource}`, `Source = .manual | .rule(Int)`, and `LeoAppearanceColor: String, CaseIterable` (10 cases; an unknown name decodes as unset, never an error).
- `LeoObservedAgent.appearance`, decoded leniently: malformed reads as nil.
- New `LeoObserveEvent.agentAppearanceChanged(seq:at:agent:appearance:)`.
- `LeoDaemonFeatures.agentAppearance`.
- Failing test first: `LeoAppearanceWireTests`, decoding the D0 fixtures with the key present, absent, partially set, an unknown color, an unknown source, and the event with null.
- Verify: `LK(LeoAppearanceWire)`, `LK(LeoObserve)`.

**L2. Rules and resolver (implement).**
- `LeoAppearanceRule` and `LeoAppearanceRulesDocument{revision, rules, errors}`.
- `LeoAppearanceResolver`, a pure function used only for the Settings preview, match counts and the source text. The daemon stays authoritative.
- `rule.summary`, which renders text like "environments contains homelab".
- Failing test first: `LeoAppearanceResolverTests` over the copied `appearance-vectors.json`. The same file has to pass in Go and in Swift.

**L3. API client (implement).**
- `LeoAppearanceAPI` protocol: `appearanceRules()`, `setAppearanceRules(_:ifMatch:)`, `setAgentAppearance(name:emoji:color:)`, where each field is `.unchanged | .cleared | .set`.
- Implement it on `LeoConfigHTTPClient` (`/api/v1`) and on the socket client, via `LeoAPIFlavor`.
- Add `LeoFakeConfigClient+Appearance`.
- Failing tests first: `LeoAppearanceAPITests` covering method, path and body per flavor, `If-Match` sent, 400 mapped to `LeoAppearanceRuleError(index, reason)`, 409 mapped to a revision mismatch, and null-vs-absent encoding.

**L4. Emoji catalog (implement).**
- `LeoEmojiCatalog`: search by CLDR short name and keywords, a "frequent" row, and `LeoEmoji.isSingleGrapheme(_:)` (`count == 1`, at most 64 UTF-8 bytes).
- The data is a **generated Swift source** file (`LeoEmojiCatalog+Data.swift`) made by `scripts/gen-emoji-catalog.swift` from a pinned Unicode `emoji-test.txt` (fully-qualified entries only). LeoKit has no `resources:`, and this keeps it that way.
- Failing test first: `LeoEmojiCatalogTests`. It covers search hits, and the validator on a ZWJ family, a flag, a skin tone, a keycap, two emoji and an empty string. Mirror the same cases in Go's D1 table.

## Phase M: Mac (after L1–L3; screenshots need L4)

**M1. Index and feed overlay (implement).**
- `LeoAgentAppearanceIndex.swift` and `LeoSidebarFeed+Appearance.swift`, mirroring the environments pair: seeded from `/state`, patched by `.agentAppearanceChanged`, overlaid only when the machine advertises `.agentAppearance` and is not disconnected.
- Failing test first: `LeoSidebarFeedAppearanceTests` (seed, set, null clears, feature absent → nil, disconnect → nil, emit only on change).
- Verify: MB, then `MT(LeoSidebarFeedAppearanceTests)`.

**M2. Row, option C (implement; the styling is a TDD exception).**
- `LeoAgentRowMetrics`: `colorBarWidth = 3` plus a gap. `nameColumnInset` includes the bar slot, so dispatch glyphs stay aligned.
- `LeoAgentRowContent`: a full-height bar or a blank spacer of the same width, then the unchanged status symbol, then the emoji as its own `Text` before the name, so fuzzy-highlight offsets still index the name.
- `LeoAgentRowPresentation`/`State`: the accessibility label adds the color name.
- New `LeoAppearancePalette+AppKit.swift`, mapping each name to `NSColor.systemX`.
- Selection ink is unchanged.
- Failing tests first: `LeoAgentRowMetricsTests` (inset equals bar, gap, symbol column and spacing; a one-line row is still 24pt) and a presentation test (highlights are unaffected by the emoji).

**M3. Appearance popover (implement).**
- `LeoAgentAppearanceModel`, which is testable on its own, and `LeoAgentAppearancePopover.swift`:
  - emoji search and grid from L4
  - palette swatches plus None
  - a source line ("Teal from rule 2: environments contains homelab"), using the rules fetched on open and falling back to "from rule 3"
  - Reset to rules
  - Edit rules…, which calls `LeoSettingsWindowController.show(selecting:host, tab: .appearance)` (add the `tab:` parameter)
- Add "Appearance…" to `LeoAgentRow` `.contextMenu`, hidden without the feature. The popover hangs off stable row identity.
- Failing test first: `LeoAgentAppearanceModelTests` (pick, clear, reset bodies; source text; error shown and selection reverted).

**M4. Settings pane (implement.hard).**
- `macos/Sources/Features/Leo/Settings/Appearance/{LeoAppearanceSettingsModel,LeoAppearanceSettingsView,LeoAppearanceRuleRow}.swift`, a tab beside Delegation, per machine via `LeoMachinePicker`. `LeoSettingsPaneState` shows `.tooOld` without the feature.
- Contents:
  - an ordered list with drag to reorder, add and delete
  - a field/op/value control per rule
  - a color and an emoji per rule
  - a count of matching agents per rule
  - a live preview column of agent → result and source, run through `LeoAppearanceResolver` on the draft against that machine's feed agents
- Explicit Save and Revert, as in the in-app settings spec. A 400 shows inline on its row index. A 409 re-reads and asks.
- Failing test first: `LeoAppearanceSettingsModelTests` (dirty state, reorder, add/delete, an invalid draft disables Save, 400 mapped to its row, 409 flow, preview and counts).

**M5. Fixture, screenshots and a real check (implement).**
- Add an `"appearance"` key to `LEO_ATTENTION_FIXTURE` (`LeoEnvironmentsFixture` pattern) with all four combinations, and have hello advertise `agent_appearance`.
- Capture with Peekaboo `--capture-engine cg` in light and dark with one row selected, plus the popover and the pane.
- Real check: the D-branch daemon via the isolated-daemon recipe, on `autopilot-scratch` only, set from the popover, with the row confirmed to update live and `agents.json` and `leo.yaml` inspected.
- Post the screenshots with `leo_chat_post`.

## Phase I: iOS (after M; reuses L1–L4)

**I1. Model (implement).**
- `Agent.appearance` in `ios/LeoFeatures/.../Models/Agent.swift`, seeded from `LeoObservedAgent`.
- `Fleet.swift` handles `.agentAppearanceChanged`.
- Failing test first: `F(FleetTests)`, adding appearance seed, set and clear cases.

**I2. Reducer and client (implement).**
- `DaemonClient` gains `setAppearance` and `appearanceRules`.
- New TCA `AgentAppearance` feature: emoji query, pick, clear, reset, rules loaded for the source line, errors.
- Failing test first: `F(AgentAppearanceTests)` with `TestStore`.

**I3. Row (implement; the styling is a TDD exception).**
- `AgentPresentation.swift` gains a `rowStyle` mapping: an emoji gives a neutral tile image with the status dot on its corner; no emoji keeps today's symbol.
- An `AgentRowTile` renderer (a `UIGraphicsImageRenderer` image fed to `UIListContentConfiguration.image`).
- The 4pt left bar through `backgroundConfiguration` in `configurationUpdateHandler`, which keeps the selection and highlight states.
- `UIColor.systemX` palette.
- Failing test first: `IT(LeoTests/AgentPresentationTests)` for the mapping.

**I4. Long-press sheet (implement).**
- `collectionView(_:contextMenuConfigurationForItemsAt:point:)` in `AgentsViewController` → Appearance (hidden without the feature).
- `ios/Leo/Agents/AgentAppearanceViewController.swift`: a UIKit sheet with medium and large detents, `UISearchTextField` plus a compositional grid, swatches, and the source line. No SwiftUI.
- Verify: IB, `IT(LeoUITests/…)`.

**I5. Fixture, screenshots and backlog (implement).**
- A `-appearanceFixture` UI test writes PNGs for all four combinations in light and dark, with one row selected and the sheet open.
- Add an autopilot backlog item: the iOS rules editor.

## Version skew

- **New app, old daemon:** there is no `agent_appearance` feature, so the app shows no menu item and the Settings pane reads "Update Leo on <machine>". Rows render as they do today because the key is absent.
- **Old app, new daemon:**
  - The `appearance` key is ignored, because decoding is keyed.
  - `agent_appearance_changed` becomes `.other(seq:type:)`, so the sequence still advances.
  - `agent_spawned` carries an extra key, also ignored.
- **Mixed machines:** gating is per machine (`features(for:)`). An old machine's rows simply show no appearance.
- **Leo.app bundles the daemon:** the app release that turns this on must bump the bundled daemon to the leo release from D6.
- Config hand-edited without a reload shows up in the next `/state`, but the live stream only changes after a reload. This is documented, not fixed.

## Risks

1. A respawn `Save` with a fresh `Record` silently wipes manual values. D3 guards against it, with a test.
2. A malformed `appearance_rules` that fails `Load` would block the whole daemon from booting or reloading. The lenient decode in D1 and its test cover this.
3. Go and Swift resolvers drift apart. One shared vector file is run by both suites, and glob is limited to `*` and `?`.
4. uniseg and Swift may disagree on grapheme clusters for very new emoji. Mitigations: mirrored validator cases, the 64-byte cap, and a daemon 400 that the UI shows.
5. The SwiftUI popover in a live list row could be dismissed by feed updates. Mitigations: stable identity and an emit-on-change-only index. If it still flickers, fall back to a sheet.
6. `nameColumnInset` grows by about 5pt, which shifts dispatch rows too. This is intended; the M5 screenshots confirm it.
7. A rules PUT rewrites `leo.yaml`: comments are lost (existing documented behavior), and other open panes get a 409.

## Open questions (defaults below; the orchestrator approves them unless Evan objects)

- **Q1:** D1 (above). **Resolved: A** (Evan, 2026-10-27).
- **Q2:** the rules PUT requires `If-Match`. Default yes, for consistency with the config API.
- **Q3:** glob supports only `*` and `?`, and anything else is rejected. Default yes.
- **Q4:** matching is case-sensitive. Default yes.
- **Q5:** `starts_with` and `glob` on `environments` match if any element matches. Default yes.
- **Q6:** the emoji catalog is the full fully-qualified Unicode set (about 3.8k entries, generated Swift). Default yes.
- **Q7:** a manual PUT on an agent with no agentstore record returns 404. Default yes.
- **Q8:** match counts in Settings include stopped agents. Default yes.

## Review gate (severity bar: fix P0/P1 and anything a real user or realistic workload can hit; record the rest as accepted risks)

- The daemon PR is reviewed and merged by the `leo` agent.
- The leoterm diffs are reviewed with `review` dispatches: one after L+M and one after I, each given the diff range and the bar. At most 2 rounds each.
- The full LeoKit, Mac (MB + Leo tests) and iOS (IB/IT) suites run once, at the merge gate.
