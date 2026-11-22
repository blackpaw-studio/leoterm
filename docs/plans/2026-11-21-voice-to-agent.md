# Voice to Agent: implementation plan

Spec: `docs/specs/2026-11-21-voice-to-agent.md` (the spec wins any conflict). Platform call: **both**. LeoKit holds the logic. iOS gets the intent, the shortcut phrase and the Control. The Mac gets the intent and the phrase.

## Facts this plan relies on (checked 2026-11-21)

- iOS sends through `ChatClient.send(connection, agent, LeoChatDraft)` (`ios/LeoFeatures/.../Dependencies/ChatClient.swift`). That calls `LeoChatHTTPClient.send` (`Packages/LeoKit/Sources/LeoKit/Chat/LeoChatClient.swift:105`, POST, `mutationTimeout` 30 s) over `LeoHTTPSTransport`.
- `DaemonConnection(daemon:secrets:)` and `secrets.connection(for:)` build credentials from `PairedDaemonsClient.load()` (a non-secret JSON file) and `SecretsClient.load` (Keychain, `AfterFirstUnlockThisDeviceOnly`).
- `AgentRef(daemonID, name)` is in **LeoFeatures**, not LeoKit. LeoKit has `LeoPushTarget(daemonID, agent)`, which has the same shape.
- The existing failure notification (`ChatNotifierClient.actionFailed`, `ios/Leo/Chat/ChatClientsLive.swift`) has **no Retry action** and drops the text. Retry is new: a new category in `LeoChatNotificationActions` and a `.retry` case in `AppFeature`, which reuses the `.reply` send path near `AppFeature.swift:384`.
- The Mac registers no notification categories and has no `AppShortcutsProvider` (Ghostty's intents are in `macos/Sources/Features/App Intents/`). Mac agents and chat come from `LeoMachineDaemon.chat` per `LeoHostID` (`LeoRuntime+Machines.swift`).
- CI runs `swift test` for LeoKit and LeoFeatures, plus app tests with `xcodebuild`.

## Step 1: Device spike — SKIPPED (Evan, 2026-11-21: "skip the phone test, make assumptions")

Assumptions the build proceeds on (each is verified at the Step 9 device checklist instead):
- **R1:** the direct POST completes in the background within the intent budget. No `.queued` path.
- **R2:** the Control runs the shared intent in the **Leo** app process, and the app UI doesn't open. Intent and entity files are compiled into both targets. If the picker query runs in the extension, the agent-directory snapshot (Decision 1) is built anyway, so the picker works in either process.
- **R3:** the Keychain is readable after first unlock. Before first unlock, the read fails and the failure path runs.
- No device build is made now. `LeoControls` builds for the simulator only. Release signing is deferred until Evan approves provisioning.

The original spike design follows for reference, should an assumption fail.

A throwaway branch `spike/voice-intents` (never merged) adds:
- a hardcoded `SpikeSend` intent in the `Leo` target (fixed agent and text, POST through the existing `ChatClient.liveValue`);
- a minimal `LeoControls` widget-extension target with one configurable `ControlWidgetButton` that runs it.

Every phase logs to `os_log` (subsystem `studio.blackpaw.leo.spike`): process name, Keychain status, POST start and end, HTTP status, elapsed ms. Evan installs a dev build on his iPhone (`xcode-remote` signed device build, or an internal TestFlight build from the spike branch). The agent supplies the checklist and reads the logs back with `log collect`.

| Risk | Run | Pass | If it fails |
|---|---|---|---|
| R1 background POST | 10 runs in each state: app killed, app backgrounded, phone locked after first unlock, cellular only (Wi-Fi off, through Cloudflare Access). Trigger from Siri and from the Action button. | ≥9 of 10 per state reach the daemon (the message appears in the thread) and return 2xx; p95 ≤10 s; the intent is never killed before it returns. | The sender gains a `.queued` result: the POST moves to a background `URLSession` upload task, Siri says "Sending to X", and the background-session completion posts Retry on failure. Steps 2 and 5 each gain one case. |
| R2 Control → in-app intent | Assign the Control (agent configured) to the Action button and run it with the app killed and with the phone locked. Also open the configuration picker. | `perform` runs in the **Leo** process (not `LeoControls`) and the app UI never opens. Also log which process serves the `AgentEntity` picker query. | Spec fallback: the Control uses `openAppWhenRun` and the app shows a minimal UIKit confirm-and-send screen. If only the picker query runs in the extension, use the agent-directory snapshot (Decision 1). |
| R3 Keychain locked | Run locked after first unlock, then again after a reboot before first unlock. | After first unlock: `SecItemCopyMatching` returns `errSecSuccess`. Before: `errSecInteractionNotAllowed`, and the intent takes the failure path (spoken message and Retry). | If the read fails after first unlock, older items likely carry a different accessibility value: add a launch step that re-saves them. If it still fails, set `authenticationPolicy = .requiresAuthentication` so Siri asks for an unlock first. |

**Output:** `docs/plans/2026-11-21-voice-to-agent-spike.md` (a results table and log excerpts). The orchestrator applies the matching fallbacks to Steps 3–7 before dispatching them.

## Step 2: LeoKit model and resolution (TDD) [parallel with Steps 3 and 4]

`Packages/LeoKit/Sources/LeoKit/Chat/LeoAgentMessaging.swift`:
- `LeoAgentTarget { machineID, machineName, agent }`.
- `displayName(among:)` returns `agent`, or `agent · machine` when the name appears on more than one machine.
- `LeoAgentResolution` is `.send(target)`, `.ask(options:, unavailable:)` or `.noMachines`, from `static resolve(configured:available:machineCount:)`.

Failing tests first (`LeoAgentMessagingTests.swift`):
- a configured agent that is present resolves to `.send`;
- a configured agent that is gone resolves to `.ask` with `unavailable` set;
- no agent configured resolves to `.ask`;
- zero machines resolves to `.noMachines`;
- the same name on two machines shows `name · machine`, and a unique name shows plain;
- the same agent name on a different machine does not satisfy a configured target.

Verify: `cd Packages/LeoKit && swift test --filter LeoAgentMessagingTests`.

## Step 3: LeoKit sender and error mapping (TDD) [parallel with Steps 2 and 4]

`LeoAgentMessageSender` takes injected dependencies:
- `machines: () async throws -> [LeoAgentMachine]`, where a machine is `id`, `name` and `agents()`;
- `chat: (machineID) async throws -> any LeoChatClient`.

It exposes two methods:
- `send(target, text) async -> LeoAgentSendResult`: `.sent`, `.unreachable(machine)`, `.unauthorized(machine)` or `.agentMissing(agent)`.
- `agents()` lists agents across all machines. A failing or slow machine is skipped rather than failing the whole list, with a per-machine timeout of about 3 s.

Error mapping (check the real thrown types in `LeoHTTPSTransport` and `LeoDaemonEnvelope` first):
- transport errors, timeouts and credential-load failures → `.unreachable`;
- HTTP 401/403 and a Cloudflare Access redirect → `.unauthorized`;
- the daemon's agent-not-found response → `.agentMissing`.

`LeoAgentSendResult` exposes:
- `outcome`, a case the apps format into localized dialog (Decision 3): "Sent to X." for success, "Couldn't reach M." for unreachable and unauthorized, "X isn't available." for a missing agent;
- `retryPayload`, non-nil for every failure except `.agentMissing`, keeping the text unchanged.

Failing tests first (`LeoAgentMessageSenderTests.swift`), with a fake `LeoChatTransport` at the HTTP boundary:
- a 2xx gives `.sent` and the request body carries the text;
- each status or error maps as above;
- a credentials throw gives `.unreachable`;
- the retry payload keeps the text.

Verify: `cd Packages/LeoKit && swift test --filter LeoAgentMessageSenderTests`.

## Step 4: Retry notification category (TDD) [parallel with Steps 2 and 3]

`LeoChatNotificationActions` gains:
- `sendFailedCategoryID = "leo.chat.send-failed"` and `retryActionID = "leo.chat.retry"`, with the category in `staticCategories`;
- `sendFailedContent(target:machine:text:)`, which builds the title, body and `userInfo` (daemon ID, agent, text);
- `LeoChatNotificationResponse.retry(LeoPushTarget, text:)`.

Tests (`LeoChatNotificationTests.swift`):
- the category is registered;
- the payload round-trips through `response`;
- an empty or missing text returns nil;
- existing categories are unchanged.

Verify: `cd Packages/LeoKit && swift test --filter LeoChatNotificationTests`.

## Step 5: iOS wiring in LeoFeatures (TDD for the reducer) [after Steps 3 and 4]

- `ios/LeoFeatures/.../Dependencies/AgentMessagingClient.swift` holds the live `LeoAgentMessageSender`. It is built from `PairedDaemonsClient`, `SecretsClient` and `DaemonClient.fetchState`, with `ChatClient` for sending, and follows the existing `liveValue`/`testValue` pattern.
- `ChatNotifierClient.sendFailed(target, machine, text)` posts a live `UNMutableNotificationContent` with the new category.
- `AppFeature` handles `.retry` like `.reply`. A retry that fails again posts a new send-failed notification, so the text is never dropped.
- Failing tests first: `TestStore` tests "retry action resends the text to the target agent" and "a retry that fails posts send-failed again with the same text".

Verify: `cd ios/LeoFeatures && swift test --filter AppFeature`.

## Step 6: iOS App Intents in the app target [after Steps 2 and 5; TDD exception: intent glue]

- `ios/Leo/Intents/AgentEntity.swift`: `AppEntity` + `EntityQuery`, with display names from `displayName(among:)`.
- `ios/Leo/Intents/SendMessageToAgent.swift`:
  - optional `agent` and required `message` (prompt: "What should I tell \(agent)?");
  - `perform` resolves, calls `requestValue` on `.ask`, sends, and returns dialog;
  - on failure it also calls `sendFailed`;
  - with `.noMachines` it opens the app with "Pair a machine in Leo first".
  - The sender comes through `AppDependencyManager`, registered in `AppDelegate`.
- `ios/Leo/Intents/LeoShortcuts.swift`: `AppShortcutsProvider` with the phrase "Tell an agent in \(.applicationName)".

Verify (`heavy`, in the background): `cd ios && xcodegen generate && xcodebuild build -project Leo.xcodeproj -scheme Leo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO`, then `git diff --exit-code ios/Leo.xcodeproj` after regenerating.

## Step 7: iOS Control extension [after Step 6; TDD exception: WidgetKit config]

- `ios/project.yml` gains a `LeoControls` app-extension target:
  - bundle id `studio.blackpaw.leo.ios.controls`, app group `group.studio.blackpaw.leo.ios`, `APPLICATION_EXTENSION_API_ONLY`;
  - embedded in `Leo`, with Release match settings like `LeoNotificationService`.
  - Its provisioning (match profile, App Store Connect identifier) needs Evan's approval before it runs.
- `ios/LeoControls/SendToAgentControl.swift`: a `ControlWidget` with `AppIntentControlConfiguration` and an optional `AgentEntity`. The intent and entity files are shared with the app target, as Step 1 proved. No secrets.

Verify: the same as Step 6.

## Step 8: Mac intent [after Steps 2, 3 and 4; parallel with Steps 5–7; TDD exception: intent glue]

- `macos/Sources/Features/App Intents/LeoAgentEntity.swift`, `SendMessageToLeoAgentIntent.swift`, and `LeoAppShortcuts.swift` (the Mac's first `AppShortcutsProvider`).
- The sender comes from `LeoRuntime`: the connected `LeoHostID`s with their agents, and `LeoMachineDaemon.chat`. It is registered through `AppDependencyManager` at runtime start.
- Failure behaviour on the Mac follows Decision 2.

Verify (`heavy`, in the background): build the Mac app per `AGENTS.md`, then `cd Packages/LeoKit && swift test`.

## Step 9: Integration gate

- Full LeoKit and LeoFeatures `swift test`, the iOS app tests and the Mac build, all under `heavy`.
- A `review` dispatch over `main...HEAD`. Bar: P0/P1, plus anything a real user can hit.
- Evan runs the spec §Testing device checklist.

**Lanes:** Step 1 first. Then Steps 2, 3 and 4 run together. Step 5 needs 3 and 4. Step 8 needs 2–4 and runs alongside Steps 5–7. Steps 6 and 7 are serial.

## Decisions (orchestrator, 2026-11-21)

1. **Picker snapshot built unconditionally** (no spike to tell us which process runs the query). The app writes a non-secret `agent-directory.json` (machine id and name plus agent names) to the app-group container on agent refresh, and the extension reads it. It holds no secrets, the app can always rewrite it, and it stays inside the spec's "the Control holds no secrets" rule.
2. **Mac failure Retry: in scope** (Evan, 2026-11-21). The spec's §5 applies to both platforms, so the Mac registers the same `leo.chat.send-failed` category from LeoKit and handles Retry through the sender.
3. **Localization:** LeoKit returns outcome cases, and each app formats them with `String(localized:)`.
4. **Implementation deviations (2026-11-21, no device spike):**
   - `LeoAgentSendResult` is an enum whose cases carry the target and the text, so `outcome` and `retryPayload` are computed from it. `LeoAgentMessageSender` also takes an injected per-machine `deadline` (default 3 s) so tests need no wall-clock wait.
   - `LeoAgentDirectorySnapshotStore` (LeoKit) writes `agent-directory.json` to the app group; `AppFeature` saves it on every `.fleet` action, and the store skips an unchanged or empty list. The picker query always reads it (Decision 1); `perform` resolves against the live directory.
   - iOS sends through `LeoChatHTTPClient` built on `LeoHTTPSTransport` directly (the sender needs a `LeoChatClient`, which `ChatClient` doesn't expose), and `AgentMessagingClient` registers with `AppDependencyManager` in `AppDelegate`.
   - On iOS `message` is `String?` and the intent asks for it in `perform` ("What should I tell <agent>?"), because a required parameter can't name another parameter in its prompt. The Mac prompt is the static "What should I tell the agent?".
   - `.noMachines` on iOS uses `continueInForeground` (`ForegroundContinuableIntent`, app-only: the `LeoControls` target defines `LEO_CONTROLS_EXTENSION` to skip it).
   - A retry for an unpaired daemon or a missing credential uses `actionFailed`, not `sendFailed`, so Retry can't loop on something a retry can't fix. A 2xx whose body won't decode counts as unreachable (a duplicate on retry beats a dropped message).
   - iOS builds use Xcode 26.5 (it has the Metal toolchain and an iOS platform); Xcode 26.3 has no iOS platform and Xcode 27 has no Metal toolchain.

## Risks

- Error mapping: a wrong mapping could say "isn't available" when the machine is actually unreachable. Step 3 verifies the real thrown types.
- The `LeoControls` provisioning is an account-level external action that needs explicit approval.
- Agent-list latency: the per-machine timeout keeps a dead machine from stalling Siri's "Which agent?".
