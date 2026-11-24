# Plan: Needs-you Inbox (Mac + iOS)

Spec: `docs/specs/2026-11-24-needs-you-inbox.md` (source of truth on conflict). Platforms: both.
Derivation, ordering, read state and badge live in LeoKit; apps own UI and glue.

## Orchestrator decisions (2026-11-24)

Accepted deviations forced by evidence:
1. **Blocked** = attention `needsInput` OR an open chat `ask`/`permission` row (the daemon never sets
   `needsInput` for chat asks).
2. Open chat **`permission` rows** are answerable inline via the existing chat answer route (same as
   the chat pane). Terminal permission prompts with no chat row stay "Go to Agent".
3. Finished list keeps read items flagged `isUnread=false` (backs iOS "Earlier" and keeps the
   selected Mac row visible until selection moves).
4. **Notifications unchanged:** after daemon D4 maps `StopFailure` → `errored`, the apps must still
   notify for it exactly as they did for `finished` (adjust `LeoAttentionReducer.swift:221` in L1).
5. Daemon work runs in an isolated worktree of the leo repo and lands as a PR the `leo` agent reviews
   and merges. App work does not wait on it (per-host 404 fallback).

## Evidence

- Open asks: `LeoChatMessage.isOpen` (`LeoChatModels.swift:150`, kinds ask + permission); input spec
  in `LeoChatAsk.swift:8-49`, `LeoChatQuestions.swift:6-14`; live via `chat.message`/`chat.updated`
  on `/api/v1/events` (`LeoActivityClient.swift:396-399`). Gap: no cross-agent open-ask route;
  `GET /api/v1/chat/threads` returns only `last_message` (leo `internal/web/handlers_chat.go:252`).
- Permission: `LeoAttentionReason{kind, tool, detail}` clamped 120 chars (`LeoAttention.swift:36-73`),
  daemon fills from PermissionRequest (`handlers_attention.go:93-132`). `detail` may be a summary,
  not the raw command (checked in A2).
- Question: bridge `kind=question` Summary as detail (`observe/bridgefeed.go:448`); elicitation only
  has server name → fall back to reason text.
- Finished one-liner: daemon sends `attention.preview` (`observe/attention.go:23-31`); LeoKit drops
  it (`LeoAttention.swift:79-82`).
- Errored: `StopFailure` maps to `finished` (`handlers_attention.go:169`). No attention timestamp.
- Multi-machine: Mac has one feed + `LeoAttentionReducer` per host (`LeoMachineFeeds.swift:56-59,160-164`);
  stale on disconnect (`LeoSidebarFeed+Disconnect.swift:35`, `LeoAttentionReducer.swift:278-289`).
- Read sync: daemon `reads(agent, last_read msg-id)` (`chat/migrate.go:53-56`); cursor can't represent
  chat-less turns and `MarkRead` emits no event → cannot carry lastSeenAt.

## Dispatch A — leo daemon PR (implement, high; parallel with B; isolated worktree)

- **A1** `agent_seen(agent PK, seen_at)`, forward-only, server time. `PUT /api/v1/agents/{name}/seen`,
  batch `PUT /api/v1/agents/seen {"agents":[…]}`, `GET /api/v1/agents/seen`; each write publishes
  `agent_seen {agent, seen_at}`. Tests first: round-trip, older write ignored, event to 2nd subscriber.
- **A2** Attention JSON gains `at` (RFC 3339, daemon clock). `StopFailure` → `errored` with clamped
  error `preview`; audit every `errored` consumer. Report whether permission `detail` is the raw Bash
  command. Tests first.
- **A3** `GET /api/v1/chat/asks?state=open`: all open ask/permission messages, oldest first. Test: two
  open + one answered → exactly two.
- Verify: `go test ./internal/chat/... ./internal/web/... ./internal/observe/...`. Bump reaches
  leoterm via the usual `bump/leo-*` PR.

## Dispatch B — LeoKit core (implement, high; this repo)

Each step starts from a failing Swift Testing test in `Packages/LeoKit/Tests/LeoKitTests/`.
- **L1** `LeoAttentionSignal` gains optional `preview` (clamped) and `at: Date?`; reducer exposes
  `committedSignal(for:)` (live only); `errored` notifies like `finished` (decision 4). Tests: with/
  without fields, malformed `at` → nil, stale → nil, errored notification.
- **L2** `Sources/LeoKit/Inbox/LeoInbox.swift`: pure `LeoInbox.derive(agents:openAsks:seen:)` →
  `blocked`, `finished` of `LeoInboxItem{kind, isUnread, isError, agent, machine, projectLabel, at,
  context, moreCount}`. Tests: each kind; chat row > permission reason > question/elicitation; chat
  ask blocked while `working`; label omitted when == agent; blocked oldest-first, finished
  newest-first; stale host contributes nothing; errored flag; one item per agent with +N more.
- **L3** `LeoInboxSeenState`, per-host `.synced([agent: Date])` | `.local([agent: SeenMark(bootID,
  revision)])`; `markSeen`, `clear(items)`, `apply(agentSeenEvent)`, Codable. Tests: synced unread iff
  `at > seen_at`; local unread iff mark differs; new revision → unread; blocked never cleared; clear
  marks all shown finished.
- **L4** `LeoInboxBadge`: `.count(blocked)` if >0, else `.dot` if unread finished, else `.none`;
  summary counts. One test per rule.
- **L5** `LeoOpenAsks` per host: `seed(host, messages, complete:)` (A3 route if present else threads
  `last_message`), `apply(LeoChatEvent)` (open add / settled remove; tracks last outbound non-ask
  message as context), `disconnect(host)`. `LeoChatClient` gains `openAsks()`, `seen()`,
  `markSeen(agents:)` returning nil on 404; `LeoActivityClient` decodes `agent_seen`. Tests: reducer
  cases, stub-transport routes/bodies, 404 fallback, event decode.
- Verify: `cd Packages/LeoKit && swift test --filter 'LeoInbox|LeoOpenAsks|LeoAttention|LeoChatClient|LeoActivityClient'`

## Dispatch C — Mac (implement, medium/high for C1; after B, parallel with D)

- **C1** Extract settle/answer from `LeoChatPaneModel.swift:50-76,289-333` into
  `Chat/LeoChatAnswering.swift` (pane + inbox share it; inbox keeps its own drafts). New
  `Inbox/LeoInboxModel.swift` over `LeoMachineFeeds`, `LeoOpenAsks` (seeded beside threads fetch,
  `LeoChatUnreadStore.swift:110`), seen state (UserDefaults in local mode). Mark-seen: chat pane read
  (`LeoChatPaneModel.swift:242`), terminal focus (`LeoWindowSession.swift:457`), inbox selection.
  Tests first (`macos/Tests/Leo/`): 409 → settled & dropped; terminal focus marks seen; live ask
  appears in one event. Existing chat pane tests stay green.
- **C2** (UI, TDD-exempt except one test) `.inbox` in `LeoSidebarItemID` (`LeoSidebarSelection.swift:13-17`),
  pinned row under search (`LeoSidebarView.swift:168-186`) with L4 badge, content switch
  (`LeoSidebarSplit.swift:238`). Test: selecting Inbox keeps agent selection model intact.
- **C3** (styling TDD-exempt) list + detail per spec/mockup A; keyboard ↑/↓ ↩ ⌘↩ ⌫ following
  `LeoSidebarReturnKey.swift`; empty state. Test keyboard → action mapping only.
- Verify (background, `heavy`): `cd macos && DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer
  xcodebuild test -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64'
  -skipMacroValidation -packageAuthorizationProvider netrc CODE_SIGNING_ALLOWED=NO
  -only-testing:GhosttyTests/LeoInboxModelTests -only-testing:GhosttyTests/LeoChatAnsweringTests`,
  then a Peekaboo screenshot with a scratch agent asking via `leo_chat_ask`.

## Dispatch D — iOS (implement, medium; after B, parallel with C)

TCA `TestStore` tests in `ios/LeoFeatures/Tests/LeoFeaturesTests/ChatListTests.swift`.
- **D1** Errored → `.done` (`ChatList.swift:49`); `counts.needsYou` excludes it.
- **D2** `ChatList.State` gains `openAsks`, `seen`, derived `inbox`; seed from threads + openAsks/seen
  responses; `chatEvent` applies asks; `agentSeen` action; `askAnswered` via `chatClient.answer`/
  `answerQuestions` (`Dependencies/ChatClient.swift:39,77-79`); `clearFinishedTapped`; opening an
  agent marks seen (`AppFeature+Routing.swift:70,76`). Tests: answer removes card; 409 settles; clear
  marks all; open sends markSeen; local mark persists via `@Dependency` store.
- **D3** Tab badge from `LeoInboxBadge` (`RootTabBarController.swift:85`); test state property only.
- **D4** (UIKit, TDD-exempt) cards in `ios/Leo/Chat/ChatsViewController.swift` per spec/mockup.
- Verify: `cd ios/LeoFeatures && swift test --filter ChatListTests`, then simulator screenshot via
  xcode-remote.

## Integration gate

1. Review B+C+D (`review`) and A (`review.concurrency`, leo repo).
2. Full LeoKit, Mac and iOS suites under `heavy`.
3. After A ships and is bumped: cross-device E2E (ask on remote host shows + answers in both apps;
   opening on Mac clears iOS dot).

## Risks

- Local-mode marks re-flag finished items once after daemon restart; Mac/iOS disagree until A ships.
- Permission `detail` may be a summary; then show summary + Go to Agent.
- C1 touches the live chat answer path; regressions there affect every agent's chat.
- `leo` agent may reject D4; then the error flag only appears for other `errored` sources.
