Status: running
Started: 2026-09-30T18:19:05Z
Budget: 20 items, until 2026-10-01T06:19:05Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-09-30: previous run finished cleanly. main == autopilot (46fbb909d). Inbox: B-058 answered "punt" → parked as idea (D-212), held lane kept as-is; /feature "In-app updates on" → B-115, placed at the top of the queue (above the promoted polish items, per the /feature intent). B-087..B-114 promoted. Stale landed lanes B-054..B-086 still on disk (finish could not remove them last run).

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-09-30T14:49:01Z
- Board sync: B-014: unknown status [deferred] (exit 1)

Lane: B-090
  Branch: autopilot-lane/B-090
  Base: 7c2f61a96d53b634458dc895c3c85941a68735db
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 988d3dca0db89b37c8662ed8625f7085831cc684
  Dispatched: 2026-09-30T18:21:35Z
  Call: Launch test asserts "terminal fills the split" rather than "sidebar frame is 0" (a collapsed item keeps a stale 200 pt frame; the terminal width is what the user sees) — AUTONOMY test-infra latitude
  Call: B-084's aHiddenSidebarShownAfterLaunchOpensAtTheStoredWidth now uses `try #require(sidebarItem.isCollapsed)` instead of forcing isCollapsed = true, which had masked this bug — AUTONOMY test-infra latitude
- B-090 runner: ready at 988d3dca0 (general full; implementer/opus; 0 fix rounds; 1850/1850 green). GUI: hidden sidebar stays collapsed through relaunch; re-show restores 330 pt.
- B-090 landed (merge 24dfd079f).
Finished 1: B-090 landed 24dfd079f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-090-1.png

Lane: B-092
  Branch: autopilot-lane/B-092
  Base: 6d0774aae56de0e3550d1f882ffd0b3882f3eb4e
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 70179b89152f96e0d3893aac41fdc2bbe5204083
  Dispatched: 2026-09-30T22:04:26Z
  Call: Store the exiting mark inside the existing lock file, not a separate marker or a LaunchServices check (B-085 showed isTerminated is unreliable) — AUTONOMY implementation approach
  Call: The waiting copy shows no UI and has no timeout while a quitting holder is alive — P5, P2
  Call: Mark on quit approval (every terminateNow/true reply) plus in applicationWillTerminate as a backstop — AUTONOMY bug fix
  Call: Wait on the marked pid via kqueue NOTE_EXIT, then a bounded ~5 s release retry (2 ms × 2500) covering XNU's exit-before-flock-release gap, then yield per D-051 — P5 (not a user-facing retry)
  Call: A failed truncate on acquire refuses with the D-053 alert — D-053
- B-092 runner handed back mid fix round 1 (harness forced handback; "Error" was the cutoff, not a failed command). Blocking finding open at e03a59f96: blocking flock waits on whoever holds the lock, not the dying marked holder. Its implementer-hard kept running in the lane; waiting for it to go quiet, then a fresh build runner (fix round 2 context).
- B-092: orphaned implementer-hard finished fix round 1 at 8094e6416 (pid-in-mark + kqueue NOTE_EXIT wait + non-blocking re-acquire; bounded 5 s release retry deviation). Its full suite timed out at load 200-460 (not green). Orphaned fixture pid 22743 (fake_ssh.py) left alive; kill was denied to it and not done here. Fresh build runner dispatched to resume at integrate/review/verify, Fix-base e03a59f96.
- B-092 runner and its reviewers/verifier died on an expired OAuth token (401) after integrating (eaa8a9594). Evan re-ran /login; redispatched the same resume brief rather than stopping the run. The dead verifier's suite (pid 47142, timeout 3000) was still running in the lane.
- B-092 runner: ready at 70179b891 (general/concurrency/security delta from e03a59f96; both blocking findings confirmed fixed). 1875/1875 on run 3 (two unrelated load flakes in runs 1-2). GUI race 12/12 left exactly one Leo; D-051 holds.
- B-092 landed (merge 22fe40225).
Finished 2: B-092 landed 22fe40225 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-092-1.png

Lane: B-097
  Branch: autopilot-lane/B-097
  Base: c8718647a94978eca08f0461faaa7a577a684c58
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: f188dfa0887a59e707c4a343d3e69588d40721d1
  Dispatched: 2026-09-30T22:20:59Z
- B-097 runner: ready at f188dfa08 (general full; 1876/1876; GUI: Return To Default Size on a filled start screen → configured size + sidebar, no shrink).
- B-097 landed (merge 79c3dd7b6).
Finished 3: B-097 landed 79c3dd7b6 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-097-1.png

Lane: B-109
  Branch: autopilot-lane/B-109
  Base: 6dac1903eae33858817f3a036ddc268dce33fa22
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-09-30T22:37:30Z
  Call: Treat the post-close linger as intended: the shell lives only while ⌘Z can restore the pane (Ghostty undo-timeout, 5 s default), with no product fix — P1, AUTONOMY bug fixes/test infrastructure (consistent with D-140/D-141/D-198)
  Call: Put the pins in LeoTerminalRowsIntegrationTests, reusing freshUndo/openSplit/closePane/Weak — AUTONOMY test infrastructure
  Call: shellPID waits for a foreground process named other than ""/"login" (setuid /usr/bin/login owns the pgid first) — AUTONOMY test infrastructure
- B-109 runner: blocked, couldn't reproduce. Closed pane's shell lives exactly for the Close Terminal undo window (5 s undo-timeout); pin tests 14c6dae64 + doc a5462b28a unreviewed, not integrated.
