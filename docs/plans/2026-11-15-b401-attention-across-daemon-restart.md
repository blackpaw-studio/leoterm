# B-401: finished agents revert to idle after a relaunch

Report: when you relaunch all the finished agents in the sidebar revert back to idle. Can the sidebar pick up the same state when relaunching?

Owner decision D-815: fix lives in the leo daemon (same pattern as D-788 and D-785/B-219). This repo gets the repro, the contract, and Swift pins. No app production code changes. The item stays open until a bundled leo includes the fix.

**Platform call: both Mac and iOS, no app code.** The fix is in the daemon, so every machine gets it (P3). Pins live in LeoKit, the Mac feed tests, and iOS `FleetTests`.

## Root cause

leo v0.83.0 (`02dc4d5d`) keeps attention in memory only (`internal/observe/attention.go`). On startup it re-adopts each running hooked agent as `unknown` (`internal/service/process.go:1550-1555`: "Attention does not survive a daemon restart; an agent launched with hooks is unknown until its next hook fires"). The app commits that `/state` baseline and the row reads idle. The app must not invent a state the daemon did not report (P2), so this cannot be fixed client-side.

A plain app relaunch keeps `finished`: quitting the app does not stop the daemon (`LeoRuntime.swift:642`). The revert needs a daemon restart. That happens on the first launch after an update (`restartIfUpdated`, `LeoManagedStartup.swift:89`) and on a remote leo upgrade. Both are exactly when a user relaunches.

## Repro (2026-11-15, isolated daemon + lane debug app)

Setup: copy of the installed leo 0.83.0 on `-c` scratch config (`/private/tmp/claude-501/b401e2e`), stub `claude`, agent `autopilot-scratch` only, lane debug `Leo.app` (`studio.blackpaw.leo.macos.debug`) with `HOME`/`CFFIXED_USER_HOME`/`TMUX_TMPDIR` pointed at the scratch dir. Evidence is in `2026-11-15-b401-attention-across-daemon-restart-evidence/`.

| Step | Action | `/state` attention | Row |
|---|---|---|---|
| a | `Stop` hook posted (with the agent's launch session id) with the agent's attention token (`POST /api/agent/hook`) | `{"state":"finished","revision":2,"preview":"done"}` | green check (`a-finished-row.png`) |
| b | Quit and relaunch the debug app only | `finished`, revision 2 | green check, unchanged (`b-after-app-relaunch-row.png`) |
| c | SIGTERM the isolated daemon, start it again (tmux session survives, agent re-adopted) | `{"state":"unknown","revision":1}` | idle moon (`c-after-daemon-restart-row.png`) |

(b) confirms there is no app-side loss. (c) reproduces the report.

## Contract request for the leo daemon

Persist at-rest attention across a daemon restart.

1. Persist `finished`, `needs_input` and `errored`, each with its reason/preview, keyed by agent name AND the agent's attention token (the token is already stored in `agents.json`, `AttentionToken`).
2. On adopt after a restart, restore the record only when the stored token equals the adopted launch's token. A fresh launch (new token) or a recreated agent inherits nothing and starts `unknown`.
3. Restored attention is served at a revision above anything served before the restart, so `/state` and SSE stay monotonic for consumers that compare revisions.
4. `working` is not restored; it comes back as `unknown`, so a lost `Stop` hook cannot leave an agent stuck as working.
5. JSON shapes of `/state` and SSE and the boot id semantics do not change. A new boot id still tells clients to re-baseline.
6. Persist atomically under the daemon state dir (write temp + rename) and prune the record when the agent is deleted.
7. Known narrow window: a `Stop` hook fired while the daemon is down is lost, so the agent shows its pre-restart state until the next hook. Accepted.

## Go test spec (red on v0.83.0)

- `TestAdoptAfterRestartRestoresAtRestAttention`: agent finished at revision N, daemon restarted, same name and attention token adopted. `/state` reports `finished` with its reason at a revision > N. A later `UserPromptSubmit` hook commits `working`.
- `TestRestartDoesNotRestoreWorking`: `working` before the restart comes back as `unknown`.
- `TestFreshLaunchDoesNotInheritAttention`: a new attention token, or a recreated agent, comes back as `unknown`.
- `TestRestoredAttentionSurvivesForNeedsInputAndErrored`: both states round-trip.

## App-side pins (pass today, by design)

They pin how the app treats a daemon boot change once the daemon serves restored state, as B-219 did. They are not the reproduction; the daemon repro above is.

- LeoKit `LeoAttentionReducerTests`: `bootChangeBaselineKeepsRestoredFinished`, `bootChangeBaselineUnknownShowsNoBadge` (the second pins P2: the app never carries `finished` across a boot itself).
- Mac `LeoSidebarFeedAttentionRecoveryTests`: `relaunchBaselineShowsFinishedRow`, `daemonRestartBaselineShowsRestoredFinished`.
- iOS `FleetTests`: `aDaemonRestartSnapshotKeepsRestoredFinished`.
- Already covered, so not duplicated: `baselineReplacesStateEvenAtALowerRevision` (LeoKit), `aDaemonRestartDropsAttentionFromThePreviousBoot` (iOS).

## Out of scope / notes

- Dock acknowledgements live in memory, so restored `finished` agents count in the dock badge again after a relaunch. Existing behaviour.
- The leo release and the bundled-leo bump belong to the leo agent and Evan.

## Send record

**Not sent yet (2026-11-15 19:0x EST).** The run had no `leo_send_message` tool, and the fallback `SendMessage` to `leo` was denied by the auto-mode permission classifier ("Undermining Oversight"). Nothing was sent by another route. The contract and Go test spec above are the message body; the orchestrator (or Evan) needs to send them to the `leo` agent via `leo_send_message` (target `leo`) and record the time here. No reply yet.

Mac also carries one extra pin, `daemonRestartBaselineWithUnknownClearsTheRow` (the Mac twin of the LeoKit P2 pin).
