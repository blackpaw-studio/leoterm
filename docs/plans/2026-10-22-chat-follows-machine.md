# Plan: Leo Chat follows the agent's machine (Mac)

Spec: `docs/superpowers/specs/2026-10-21-leo-machines.md`, section "Amendment 2026-10-22". If this plan and the spec disagree, the spec wins.
Branch: `fix/chat-follows-machine`. Platform: **Mac only.** iOS already talks to each agent's own daemon (see "iOS finding" below), and LeoKit does not change.

## Root cause
- `LeoRuntime.swift:315-325` builds one `LeoChatUnreadStore` and one `LeoChatPaneModel` on This Mac's socket client, with `host: .local`.
- `LeoRuntime.swift:361` tags every chat delivery `.local`, and `LeoMachineFeeds.swift:137` forwards chat only from This Mac's feed.
- Commit a87b3b0db (S5) removed the only callers of `chat.updateClient` / `unread.updateClient`, which used to sit in the old `applyConnected`.
- So for any remote agent, `LeoChatPaneModel.loadNewest` hits its guard at `LeoChatPaneModel.swift:154` and shows "<Machine> isn't connected."

## Design
- **One chat client per connected machine**, built next to that machine's daemon client.
  - `LeoMachineDaemon` (`Integration/LeoRuntime+Machines.swift:5`) gains `let chat: any LeoChatClient`.
  - `tunnelledDaemon` builds it with `LeoChatPaneModel.makeClient(socketPath:transport:)` over the same `LeoTunnelSocketTransport` the daemon client uses.
  - This Mac uses the injected or local `chatClient`. Bring back `private let localChatClient`.
  - The init gets no default for `chat`, following the existing rule that a missing production dependency must not compile silently.
- **The pane and the unread store each hold `[LeoHostID: any LeoChatClient]`** and look the client up by `agent.host`.
  - `bind(_ client:host:)` and `unbind(_ host:)` replace `updateClient`. Both are synchronous and do no I/O.
  - With this lookup, switching agents across machines needs no rebinding. `show(agent)` simply uses `clients[agent.host]`.
- **The runtime drives the lifecycle**, in `LeoRuntime+Machines.swift`:
  - In `applyConnected`, after the sequence/generation guard and **before** `feeds.updateConnection(.connected)`, call `chatMachineConnected(host, client)`. It runs `unread.bind`, then `chat.bind`, then `chatRelay.send(.init(host:, signal: .resync))`.
  - The synthetic resync goes through the same ordered relay as live events. It reseeds that machine's unread counts and reloads the shown thread if that thread is on the machine.
  - The feed's own hello sends a second resync. That one is harmless, because the seed and page tokens drop the stale answer.
  - On `.connecting` and `.failed` in `applyConnection`, and for every `gone` host in `machinesChanged`, call `chatMachineDisconnected(host)`. It runs `unread.unbind` and `chat.unbind`.
  - This Mac follows the same path, so it binds on its first `.connected`. Nothing is bound at construction any more.
- **Every machine's feed forwards chat, tagged with its host.**
  - `LeoMachineFeeds.Dependencies.onChat` becomes `(LeoHostID, LeoChatFeedSignal)`.
  - `makeEntry` forwards `onChat(host, signal)` only when the feed's own `from == host`. This replaces `isLocal, from == .local`.
  - `LeoRuntime.swift:361` passes `host` through.
- **Late replies from a machine that has left are ignored.**
  - Pane: `unbind` bumps `loadToken`, so in-flight pages are dropped. `receive` and `resync` also require `clients[host] != nil`.
  - Unread: each host has its own seed token, and unbinding bumps it. `receive` ignores hosts that aren't bound.
  - Relay sink: auto-open runs only when `unread.isBound(delivery.host)`.
- **Unread is one store with per-host state.** `LeoChatUnreadCounts` (LeoKit) is already keyed by `LeoAgentID` (host + name), and `seeding(_:host:)` already replaces only that host's counts, so the published `counts` and `count(for:)` stay as they are. These become per host: `clients`, seed task, seed token (never reset), `readSinceSeedBegan`, and `liveKindsSinceSeedBegan`. A seed clears only its own host's entries from those sets.
  - `bind` does **not** seed. The runtime's synthetic resync does that. Seeding inside `bind` would race live events in unit tests and add an extra `threads()` call.
  - `unbind` cancels the host's seed, bumps its token, and drops the host's counts (`counts.seeding([], host:)`) and its `latestKinds`.
- **The pane on `unbind` of the shown agent's machine** gets the same state as selecting that agent while the machine is down:
  - the timeline is reset (task filter kept);
  - `isLoading` and `isLoadingOlder` are set to false;
  - `loadError = "<Machine> isn't connected."`.
  - Drafts are kept. Reconnecting reloads the thread through the synthetic resync.
- **Attachments** are fetched with the shown agent's machine's client. The cache keys stay as attachment ids, because daemon ids are ULIDs with crypto entropy (`leo/internal/chat/ulid.go`), so ids from different machines don't collide.

## Verification commands
- **Prereq (worktree):** `ln -s ~/.leo/agents/leoterm/macos/GhosttyKit.xcframework macos/GhosttyKit.xcframework && ln -s ~/.leo/agents/leoterm/zig-out zig-out`.
  - That build is from 2026-10-20, newer than the last `src/` commit, c3bfaf7de (2026-10-10). This change touches no `src/`.
- **MB** (from `macos/`): `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer xcodebuild build-for-testing -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -packageAuthorizationProvider netrc -skipMacroValidation -derivedDataPath build/DD CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO ENABLE_HARDENED_RUNTIME=NO`
- **MT(S…)** (from `macos/`, one `-only-testing` per suite): `DEVELOPER_DIR=/Applications/Xcode-26.3.0.app/Contents/Developer /opt/homebrew/bin/timeout 600 xcodebuild test-without-building -project Ghostty.xcodeproj -scheme Ghostty -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DD -skipUnavailableActions -parallel-testing-enabled NO -only-testing:GhosttyTests/<S> …`
  - If the console is locked, use the injected-bundle runner described in `LEO.md`.
- **Lint:** `cd macos && swiftlint lint --strict --quiet`.

## Steps (each one is test-first: write the test, watch it fail, then implement)

### 1. Feeds forward every machine's chat, tagged
- **Files:**
  - `Sidebar/LeoMachineFeeds.swift`: `onChat` signature, `makeEntry`, and the doc comments at :13 and :25.
  - `Chat/LeoChatFeedSignal.swift`: `LeoChatFeedDelivery: Equatable`.
  - `LeoRuntime.swift:361`.
- **Failing test:** in `LeoMachineFeedsTests`, replace `onlyThisMacsFeedForwardsChat` (:14) with `everyMachinesFeedForwardsChatTaggedWithItsMachine`.
  - Both hellos arrive: `(.local, .resync)` and `(work, .resync)`. Compare them as a set, since their order isn't fixed.
  - The log type becomes `LeoLockedLog<LeoChatFeedDelivery>`. Update the suite doc comment at :7.
- **Safe on its own:** after this step the pane and store are still bound to `.local` and ignore remote deliveries.
- **Verify:** MB, then `MT(LeoMachineFeedsTests, LeoChatAutoOpenTests)`.

### 2. `LeoChatUnreadStore` keeps state per machine
- **Files:**
  - `Chat/LeoChatUnreadStore.swift`: `init()`, `bind`, `unbind`, `isBound`, per-host seeds, and `settled()` awaiting every host. Delete `updateClient`.
  - `Sidebar/LeoSidebarView.swift:128`: `.detached()` becomes `LeoChatUnreadStore()`. Delete `detached()` unless something else still uses it.
  - `LeoRuntime.swift:318`: build it empty, then `unread.bind(localChatClient, host: .local)`. That bind is temporary until step 4.
- **Tests in `LeoChatUnreadStoreTests`:**
  - `make()` (:17) becomes an empty store bound to `client` on `.local`.
  - Rename `anotherHostsSignalsAreIgnored` (:107) to `anUnboundMachinesSignalsAreIgnored`. Its body stays the same; it still expects 0 thread requests.
  - Replace `aSeedThatLandsAfterTheClientChangedIsDropped` (:115) with `aSeedThatLandsAfterItsMachineUnboundIsDropped`.
  - New `eachMachineSeedsFromItsOwnDaemonAndKeepsTheOthersCounts`: two fakes, local and `.remote("box")`. A remote resync asks only the remote fake, and local counts survive.
  - New `unbindingAMachineDropsItsCountsAndLatestKinds`.
  - New `aSeedOnOneMachineDoesNotDropAnotherMachinesSeedInFlight`.
  - New `aReadDuringOneMachinesSeedDoesNotSuppressAnotherMachinesSeed`.
  - Update the suite doc comment at :8 ("bound to one host").
- **Verify:** MB, then `MT(LeoChatUnreadStoreTests)`.

### 3. `LeoChatPaneModel` looks up the client per agent's machine
- **Files:** `Chat/LeoChatPaneModel.swift`.
  - The init takes `clients: [LeoHostID: any LeoChatClient]` instead of `client:host:`.
  - Add `bind` and `unbind` (unbind behaves as described under Design). Delete `updateClient`.
  - Add a private `client(for host) throws -> any LeoChatClient`. It throws an error whose message is "<Machine> isn't connected."
  - Use that lookup in `loadNewest` (:154 guard), `fetch`, `markRead`, `answer`, `settleQuestions`, `refreshSettled`, `download`, `send` (:468) and `startRecording` (:528).
  - `receive` and `resync` check `clients[host] != nil && agent.host == host`.
  - Update the doc comment at :9-10.
  - `LeoRuntime.swift:320`: pass `clients: [.local: localChatClient]`. That is temporary until step 4.
- **Tests:** update the four init sites: `LeoChatPaneModelTests.swift:21`, `:683`, `LeoChatQuestionsCardSnapshots.swift:54` and `LeoChatSenderSnapshots.swift:19`.
  - The existing remote-is-ignored cases at :66-68 and :119-122 stay as they are; they still hold for a `.local` agent.
- **New tests:**
  - `anAgentOnABoundRemoteMachineLoadsFromThatMachinesClient`.
  - `switchingAgentsAcrossMachinesUsesEachMachinesClient`: thread, markRead and send all go to the right fake.
  - `anAgentOnAnUnboundMachineShowsNotConnected`.
  - `unbindingTheShownAgentsMachineShowsNotConnectedAndDropsItsInFlightPage`: uses a held page.
  - `aResyncAfterBindingReloadsTheShownThread`.
  - `aLiveEventFromTheShownAgentsRemoteMachineMerges`.
  - `anEventFromAnUnboundMachineIsIgnored`.
  - `anAttachmentDownloadsFromTheShownAgentsMachine`.
- **Verify:** MB, then `MT(LeoChatPaneModelTests, LeoChatAttachmentClickTests)`.

### 4. Runtime binds chat per machine
- **Files:**
  - `Integration/LeoRuntime+Machines.swift`:
    - add `chat` to `LeoMachineDaemon`;
    - build the chat client in `tunnelledDaemon`;
    - in `applyConnected`, use This Mac's chat client and call `chatMachineConnected`;
    - unbind on `.connecting`/`.failed` and in `machinesChanged`;
    - fix the :13-14 doc comment ("This Mac's never moves Chat anywhere").
  - `LeoRuntime.swift`:
    - re-add `localChatClient`;
    - build the pane and store with no clients;
    - make `chatRelay` internal so the extension can reach it;
    - gate auto-open in the relay sink (:332) on `unread?.isBound(delivery.host) == true`;
    - rewrite the comments at :17-23.
- **Tests:** add `chat: FakeChatClient()` to the six `LeoMachineDaemon(...)` sites: `LeoRuntimeMachinesTests.swift:71,141,165,189,262` and `LeoRuntimeConnectionTests.swift:65`.
- **New tests in `LeoRuntimeMachinesTests`** use the existing `makeRuntime`, `LeoFakeTunnels` and `until`. The remote factory returns a per-host `FakeChatClient` with a page and threads set up.
  - `chatLoadsForAnAgentOnARemoteMachine`: `runtime.chat.show(LeoAgentID(host: .remote("a"), name: "a-agent"))` loads the page, and `loadError == nil`. This is the reported bug.
  - `aRemoteMachinesUnreadSeedsFromItsOwnDaemonAndCountsItsLiveMessages`: threads seed `(a, a-agent) = 2`. A `.chat` event on a's activity stream raises it to 3, and This Mac's counts stay unchanged.
  - `chatShowsNotConnectedOnlyWhileItsMachineIsDownAndReloadsOnReconnect`:
    1. Exit a's tunnel. Expect "a isn't connected.".
    2. Reconnect with `model.reconnectRequested(.remote("a"))`.
    3. Expect the page to reload and the error to clear.
    4. Expect machine b's shown thread and counts to be untouched throughout.
  - `aRemovedMachineDropsItsChatClientAndUnreadCounts`: use `Support.save([])` plus `machines.reload()`.
- **Verify:** MB, then `MT(LeoRuntimeMachinesTests, LeoRuntimeConnectionTests, LeoMachineFeedsTests, LeoChatUnreadStoreTests, LeoChatPaneModelTests, LeoChatAutoOpenTests)`, then lint.

### 5. Integration gate and real-app check
1. Check the load average first. If it is ≤ ~30, run `bash macos/scripts/leo-runtests.sh chat-follows-machine` (full suite plus lint). If it is higher, run every `LeoChat*`, `LeoRuntime*` and `LeoMachine*` suite and defer the full suite to the merge gate.
2. Get a fresh-context `review` at the P0/P1 bar: `git diff origin/main...HEAD`. If the diff touches concurrency or ordering, use `review.concurrency`.
3. Real-app check. Done means watching chat load for an agent on a remote machine.
   - **Preferred:** use the S11 topology (`docs/plans/2026-10-21-leo-machines-s11-evidence.md`): the Debug Leo.app in a Tart macOS VM as This Mac, plus a remote machine on leo ≥ 0.57, either a container or Dionysus over ssh, with a scratch agent that has chat history. Never use real agents (see the debug-app keystroke-safety memory).
   - Select the remote agent and check:
     - the thread loads;
     - the unread badge seeds;
     - a message the agent sends appears live and auto-opens Chat over the terminal;
     - a reply sends.
   - Stop the remote's tunnel. Expect "<Machine> isn't connected." and the machine's badges to clear. Click Reconnect. Expect the thread to reload.
   - Capture screenshots of each state.
   - **Confirming Evan's exact report:** build a Release app per the toolchain memory, then rsync it to the laptop and open it there, with Evan's approval, and open a Dionysus agent's chat.

## Out of scope / follow-ups
- Send stays enabled while the agent's machine is disconnected, and a send then does nothing, as it did before. A possible follow-up is to disable Send and voice notes while the machine is unbound.
- Accepted risk: a chat event that is still queued from a machine's old connection could be counted after a quick unbind and rebind. The hello resync that follows reseeds the count. Routing bind and unbind through the relay would close this, but it isn't worth the extra plumbing.

## iOS finding
iOS is fine, and no change is needed there:
- `ChatThread.State` carries the agent's `daemon: PairedDaemon` (`ios/LeoFeatures/Sources/LeoFeatures/Features/ChatThread.swift:22`).
- Every request resolves `secrets.connection(for: state.daemon)`: `ChatThread+Effects.swift:42,62`, and in `ChatThread.swift`, :218 for download and :244 for send.
- `ChatList` fetches threads per paired daemon (`ChatList.swift:83`).
- `AppFeature` routes `chat.*` events by daemon id (`AppFeature.swift:150-153`).
