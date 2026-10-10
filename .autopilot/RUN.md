Status: running
Started: 2026-10-10T16:31:47Z
Budget: 20 items, until 2026-10-10T22:30:00Z
Digested-through: 0
Filed: 0/3 bugs, 3/5 ideas
Self-filed: B-232 → B-280 idea — Dropped files keep their source file mode
Self-filed: B-232 → B-281 idea — Name-clash toast covers terminal text until dismissed
Self-filed: B-232 → B-282 idea — Workspace browser middle-truncates long file names
Untracked-left: default.profraw scratchpad/

Lane: B-058
  Branch: autopilot-lane/B-058
  Base: b25524869ca8aac8bdc3b19c366ffa3dca79a4a5
  Tier: full
  State: held
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Lane: B-143
  Branch: autopilot-lane/B-143
  Base: e23c0aa4232d0c0a670565289661884195ffae3e
  Tier: full
  State: held
  Fixes: 0
  Wip: a3fe1df0d
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-232
  Branch: autopilot-lane/B-232
  Base: a45efac49a794674b45c44152143b245338df282
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: e1b8cf49f5799926a8129b420c2a3900dd0d2ae8
  Dispatched: 2026-10-10T16:36:00Z
  Call: Port the shelved work as one squash commit instead of cherry-picks, so drift is resolved once — reversible implementation choice
  Call: Dispatch-watch panes keep Ghostty's default drop and get no upload — P2
  Call: No upload size cap; streaming bounds memory instead — P3
  Call: Shared beginGeneration(of:) bump for attachAnew and reattachInPlace — P2
  Call: Open errors come from LeoFileDescriptorSource.OpenError with the same user-facing text — P2
  Call: CancellationError passes through the staging write unchanged — P2
  Call: Every terminal drop insertion ends with a trailing space, so a single drop now ends with one too (unlike Ghostty's plain-shell drop) — P2, reversible
Lane: B-279
  Branch: autopilot-lane/B-279
  Base: 2cf579fa49d3ea30ffa24ae7d9c5d0bcce64a6f9
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: 1fc3eeac7eeb9f11b0757b83c244f39d9567edd8
  Dispatched: 2026-10-10T17:52:15Z
  Call: Name clash keeps both files, Finder-style "a 2.txt" (up to 100 tries), and never overwrites — P1, P2
  Call: Local backend also uses file promises, same path as SFTP — P3
  Call: Downloaded files get mode 0644 on both backends — P3
  Call: In-flight indicator is the existing header spinner; errors go in the existing footer, cleared only by Dismiss; no auto-retry on a lost connection — P2, P5
  Call: Outline view gains multiple selection (⇧/⌘-click, ⇧↑↓); Return opens only the focused row — P1
  Call: Footer shows upload, download and open errors together, one per line; isRootUploadProgressVisible renamed isHeaderProgressVisible — implementation approach
  Call: A promise that outlives a re-root is refused with .workspaceChanged and the footer says so — P2
  Call: Accepted risks: no quarantine xattr on remote downloads; a file being written during the download can arrive torn; a numbered name over 255 bytes fails plainly; Finder may add its own alert — P2

Finished 1: B-232 landed e2fd6c40a · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-232-1.png
Finished 2: B-279 landed 15f779df4 · screen capture, not attached

## Progress
- Preflight: merged main into autopilot (fast-forward to 0b83ccd7c); applied 2 inbox entries (B-278, B-279 added; B-232 answered → ready, D-474).
- Lane autopilot-lane/B-233 still unlanded with no block (item done); left in place.
- B-232 runner dispatched: d-2d7711f49f9c.
- B-232 landed e2fd6c40a (full, hard; 1 fix round: queued terminal drops lacked a separator; concurrency review clean on delta; suite 2500/2500; remote SFTP covered by tests, not visually). No focus/palette failures reproduced. Verify left scratch files in autopilot-scratch workspace (b232-vf-*, b232-v2-*) and /tmp/b232v2-src/.
- B-279 runner dispatched: d-b3464360863a.
- Evan (14:51 EDT): run must end by 18:30 EDT; then merge autopilot to main and cut a release (approved). Budget deadline moved to 22:30Z; no new lane after ~17:00 EDT unless it can finish by 18:30.
- Evan (14:55 EDT): build named environments (B-283) this run, next after B-279. End of run: merge autopilot to main, NO release (Evan will update Leo manually first).
- B-279 runner reported ready (1 fix round). Runner left a stray headless explore d-8a9c4160c622 (cancel timed out). Verifier left fixtures in autopilot-scratch b279v/ b279v2/.
- B-279 landed 15f779df4 (full, hard; suite 2522; GUI screen captures only; SFTP + lost-connection covered by tests, not live).
