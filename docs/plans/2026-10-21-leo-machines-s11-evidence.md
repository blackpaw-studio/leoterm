# Leo Machines S11: integration gate evidence

Branch `machines/S11` from `feat/machines` 549027854, run 2026-10-22 (EDT).
Evidence lives untracked on the build host under
`~/.leo/agents/leoterm/scratchpad/s11-evidence/` (written `E/` below).

## Topology

- "This Mac": Tart clone `s11-mac` (macOS VM) running the Debug Leo.app and leo 0.57.0.
- Remotes: Tart clone `s11-remote` (macOS, "Mac Remote") and two Debian containers
  (`s11-linux-a`, `s11-linux-b`), all on leo 0.57.0 with `machine_stats`.
- The golden `leo-vm` was never booted; the clones and containers were deleted afterwards.

## Gates

| Gate | Result |
|---|---|
| MB (macOS build, Xcode 26.3) | pass |
| MT (GhosttyTests, full) | 3266 tests / 341 suites, 1 failure: `LeoMachineConnectionTesterTests/aTunnelThatHangsTimesOutAndIsTornDown` (test race, fixed below) |
| LeoKit `swift test` (Xcode 26.5) | 395 tests / 43 suites pass |
| LeoFeatures `swift test` | 202 tests / 18 suites pass |
| iOS build-for-testing / UI tests | pass; 13 UI tests, 9 pass, 4 skipped (E2E without a pairing payload) |
| swiftlint `--strict` (LeoKit, macos) | clean |

MT failure cause: the test fired the 20 s connect timeout before the
connection had built its tunnel. `LeoMachineConnection.run` re-checks
`isShutDown` before `makeTunnel`, so no tunnel was launched and none leaked,
but the test expected one to have been terminated. Under host load 45+ the
timing flipped. A temporary 150 ms home-lookup runner reproduced the failure
deterministically. The fix makes the test wait for the tunnel before firing
(5ae5cfd97). The suite then passed with the delay in place and 5 times without it.

## Live Mac acceptance

| Criterion | Result | Evidence (`E/`) |
|---|---|---|
| All machines grouped, ordered as in Settings | pass | 01-sidebar.png, 02-all-connected-sidebar.png |
| Meters refresh every ~5 s | pass (CPU changed at :45/:51/:56/:01; normal and critical colours seen) | refresh/cadence.txt, refresh/timeline.txt |
| Spawn on each remote from the sheet; agent lands in its section | pass (Linux A, Linux B, Mac Remote, This Mac) | 12-, 13-, 14-, 17-spawned-all.png |
| Network loss on one remote: others keep working; offline + Reconnect; recovers | pass (backoff 2/4/8/16/32/60 s, auto-recovered) | 34-, 35-macremote-backoff.txt, 36-, outage/ |
| Daemon kill on one remote | partial: offline + Reconnect correct, others unaffected, Reconnect recovers; **no automatic retry** (finding 1) | 30- to 33-, outage/linux-a-cpu-during-outage.txt |
| Settings ▸ Machines Disable / Enable | pass (only that tunnel stops; section hidden; Enable restores) | 43-, 44-, 45- |
| Test Connection per-step results | pass (success and daemon-down cases) | 41-, 42- |
| All 5 Stats styles apply live | pass | styles/ |
| Off stops polling | pass (connects per 20 s: 19 active, 2 Off) | 50-polling-off.txt |
| Quit with 3 tunnels < 3 s, no orphan ssh | pass (0.20 s, 0 leftover) | 61-quit-3-tunnels.txt, 60-before-quit.png |
| Crash leaves orphans that the next launch reaps | pass | 21-crash-orphans.txt |
| Picker rows: status dot + meters in dark mode | pass | 51-, 52-picker-*-crop.png |
| Picker: unreachable machine | red dot + "Unreachable · reason"; selecting it is refused | 53-, 54- |

## iOS

Pass. The iPhone 17 Pro simulator paired with the leo daemons in both macOS
clones (`S11-This-Mac`, `S11-Mac-Remote`). Machines lists both as Connected
with live capsule meters, in light and dark (`E/ios/machines-light.png`,
`E/ios/machines-dark.png`, `E/ios/machines-one.png`). The test was a
temporary, uncommitted UI test. The app has to be signed (ad hoc is enough)
for the Keychain to work: the gate's `CODE_SIGNING_ALLOWED=NO` build fails
pairing with "A required entitlement is not present".

## Findings

Fixed on `machines/S11`:

1. **Daemon-only failure never auto-retried** (e412c6ca8, 68621a44c). A daemon
   that died behind a live tunnel, or This Mac's, left the machine failed until
   Reconnect, with a green Settings dot. The feed's drop now fails the
   connection into the registry's backoff. Seen live in a fresh VM clone:
   Linux A and This Mac each retried at 1/2/4/8…s and came back on their own
   once their daemon did, and the Settings dot followed (`E/fix/`).
2. **Stale iOS E2E test** (c11698e9a). `LeoE2ETests.swift:40` waited for an
   Agents-header "Connected" that S10 hides with one machine paired; it now
   reads the status off Machines. Passed against a real daemon (`E/ios-e2e/`).
3. **"1 agents"** on iOS and in the Mac header's VoiceOver label, and **the
   offline header's stale agent count** (0a6add0ac).

Not fixed:

4. **Agents ▸ New Agent… sheet can't be cancelled** and blocks Quit.
   Pre-existing on main (B-284); filed separately.
5. Minor: sheet/header icon buttons have empty AX titles; stats request
   timeout is 3 s (plan said 2 s); remote attach needs `xterm-ghostty`
   terminfo on the remote (environmental).

## Unverified

- Meter tooltips: hover never surfaced one through the VM harness; the text is
  covered by unit tests.
