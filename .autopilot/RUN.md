Status: running
Started: 2026-09-30T02:53:08Z
Budget: 20 items, until 2026-09-30T14:53:08Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out
Untracked-left: /Users/evan/.leo/agents/leoterm/.git/autopilot/lanes/B-071: macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-09-30: B-071 recovered (verifying, Wip: none, tip bc8aae9f1 = Reviewed-tip; the previous run's orphaned verifier passed it post-stop). main already merged. Inbox: 3 bugs → B-084..B-086. No new vetoes or answers. B-076..B-083 promoted. Stale landed lanes B-054..B-070 still on disk.

Lane: B-071
  Branch: autopilot-lane/B-071
  Base: dc69452597d918d43a9d1746729a6970d0fe5e67
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 1
  Reviewed-tip: adafa81c80d06f380c6996a9eab8900d0dcda75e
  Dispatched: 2026-09-30T02:54:27Z
  Call: After a content swap, the start screen, or the unsaved-edits start screen, ⌘Z does nothing to that window's tree (undo is dropped, not replayed) — P2, D-111/D-116
  Call: Clearing covers every undo action targeting that controller (tree edits, redos, its New Window); other windows' undo is untouched — P2, AUTONOMY implementation approach
  Call: When a selected row closes by any path, the selection returns to what the window shows (its row, or none so the agent's selection shows) — P6, D-116
  Call: Clear undo in leoKeepForUnsavedEdits where the tree is emptied, not in fillPlaceholder's refill branch — AUTONOMY implementation approach
- Board sync: B-014: unknown status [deferred] (exit 1)
- B-071 runner (re-verify): ready at adafa81c8 (1737/1737, lint clean; general delta, code identical to reviewed bc8aae9f1; no implementer). GUI: split, ⌘W, ⌘T, ⌘Z replays nothing; busy row's shell survives. Verify note: ⌘D / Split Right now open the agent palette (pick Plain Shell). Polish filed as B-087, B-088.
- B-071 landed (merge 8cede5a7f).
Finished 1: B-071 landed 8cede5a7f · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-071-1.png

Lane: B-084
  Branch: autopilot-lane/B-084
  Base: 5d2ab05b759c7ecc1c51228732495fc12b617d82
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: c0a13e45d7d4998f3720841fd6bc1e3ddc63b257
  Dispatched: 2026-09-30T03:10:37Z
  Call: Keep the injected UserDefaults key `leo.sidebarWidth` (one width shared by all windows, last change wins) rather than NSSplitView autosaveName — P1, P6, AUTONOMY implementation latitude
  Call: Restoring the width must cause no visible jump at launch — P2
  Call: Tests go in the existing LeoSplitViewRepresentableTests.swift, not a new file — AUTONOMY test infra
- B-084 runner: ready at c0a13e45d (1740/1740, lint clean; general full; implementer/opus, 0 fix rounds). Red confirmed (stored 200 not 360). GUI: 330 and 420 survived quit/relaunch. Debug-domain leo.sidebarWidth left at 330. Polish filed as B-089, B-090 (bug: hidden sidebar un-collapses at launch), B-091.
- B-084 landed (merge 2dc23544c).
Finished 2: B-084 landed 2dc23544c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-084-1.png

Lane: B-085
  Branch: autopilot-lane/B-085
  Base: 87ca72ee58584c7801ce70eca978860b88296fa5
  Tier: full
  State: landed
  Fixes: 2
  Wip: none
  Reverifies: 0
  Reviewed-tip: 976d04bdd57dee6370d842b4d9041959754c2c30
  Dispatched: 2026-09-30T03:41:15Z
  Call: A launch that never becomes active still opens its window — P1
  Call: Saved frames below a usable minimum (300x150, or window.minSize if larger) are neither saved nor restored; the saved origin is kept when the size is refused — P1/P2, D-036
  Call: An untouched launch window gives way to the first window a request opens through newWindow/newTab (AppleScript, Intent, Service, open-file, notification); it closes only once the requested window is visible, which takes its spot — P2, AUTONOMY
  Call: "Touched" means any key, mouse or scroll event in Leo; a launch window with a sheet up, or a newWindow whose explicit parent is the launch window, is kept — AUTONOMY
  Call: The launch window opens as the bare start screen, not through the palette route (no palette flash or stuck clipped palette on background launch) — P2
  Call: NSApp.activate is kept in the placeholder presentation, so background and login-item launches come to the front — P1
  Call: An XCTest host never adopts its launch window — D-057
  Call: Log line "opening the initial window on <event>"; callback types are @MainActor @Sendable — AUTONOMY implementation approach
- B-085 runner: ready at 976d04bdd (1787/1787, lint clean; general+concurrency full then delta; implementer-hard/opus, 2 fix rounds). Root causes: (A) first window opened only on first activation (background launch gave no window 15/15); (B) tiny saved frames (266x221) persisted, likely B-086's downstream. GUI: plain 8/8, background 5/5, relaunch 3/3, cold folder 3/3, one window every time. Fix C (quit-then-reopen race, 1/5 forced) not built, filed B-092. AppleScript/Intents/Services not driven live (no TCC consent); covered by integration tests. Polish filed as B-092..B-095.
- B-085 landed (merge feb25ef04).
Finished 3: B-085 landed feb25ef04 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-085-1.png

Lane: B-086
  Branch: autopilot-lane/B-086
  Base: 8b5ef5fe1346cd7c5e0f5bd743ba8be58cc3435b
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 25d982e73823046ba4393d953ea82fdb0204c925
  Dispatched: 2026-09-30T06:45:29Z
  Call: A window already on screen keeps its frame on its first attach; window-width/window-height size only a window that gets content before it is shown — P1, P2 (D-145 no-jump)
  Call: A window counts as shown once its first presentation has run, so a minimized window or a hidden app also keeps its frame — P1
  Call: windowDidLoad and first fill share one explicit size formula (leoConfiguredContentSize) instead of the SwiftUI intrinsic size — AUTONOMY implementation approach
  Call: Integration tests save and restore NSWindowLastPosition in the debug app's defaults — AUTONOMY test infra
- B-086 runner: ready at 25d982e73 (1787/1787, lint clean; general+concurrency full; implementer-hard/opus, 0 fix rounds). Root cause (stack trace): first fill of a shown start screen applied SwiftUI's intrinsic size (800x114, cell size 0) when the config sets window-width/window-height; window shrank 800x632 to 800x146. Evan's laptop config likely sets them. GUI: first attach to autopilot-scratch kept 800x632, also after relaunch. Polish filed as B-096, B-097 (bug: Reset Window Size same shrink).
- B-086 landed (merge 610f7170c).
Finished 4: B-086 landed 610f7170c · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-086-1.png

Lane: B-072
  Branch: autopilot-lane/B-072
  Base: efe117dd0be9de6cc50a48536665905d86704786
  Tier: full
  State: landed
  Fixes: 1
  Wip: none
  Reverifies: 0
  Reviewed-tip: a88c3c1b2b6e1e76241df59f38cfb2c45ebb5048
  Dispatched: 2026-09-30T07:24:32Z
  Call: Fix the hazard in libghostty (src/global.zig only) rather than with a test-only workaround — AUTONOMY: approach; minimal Zig
  Call: Keep the tests' setenv calls as the regression — AUTONOMY: test infra
  Call: Lengthen aNewShellIsASelectedRowTitledByItsTerminal to 10 s even though B-068 made it mostly moot — AUTONOMY: flake fixes
  Call: The environ arena keeps each copy until deinit (grows once per sync), so readers of an older snapshot stay valid — AUTONOMY: approach
  Call: io_impl.environ_initialized is not reset; memoised PATH/HOME are dropped, not rebuilt (avoids touching std Io.Threaded internals) — AUTONOMY: approach, minimal Zig
  Call: No shared env lock with LeoTunnelTestSupport; the burst stays in process — AUTONOMY: test infra
  Call: init uses a fallible syncEnvironOrErr (ghostty_init fails cleanly on OOM); GTK keeps the void log-and-keep syncEnviron — AUTONOMY: approach
  Call: Zig comments don't mention B-072 (keeps the upstream diff neutral) — AUTONOMY: minimal Zig
- B-072 runner: ready at a88c3c1b2 (wrapperless 1788/1788 twice, lint clean; general+concurrency+security full then delta; implementer-hard/opus, 1 fix round). Fix in src/global.zig: syncEnviron keeps its own copy. GUI smoke: New Terminal rows spawn, HOME/TERM reach the child. verify.md updated (orchestrator). Shared post-B-072 xcframework copied to .git/autopilot/shared/. Red runs left 5 .ghosttycrash files in ~/.local/state/ghostty/crash/ (not deleted). Polish filed as B-098.
- B-072 landed (merge 668489764).
Finished 5: B-072 landed 668489764 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-072-1.png
