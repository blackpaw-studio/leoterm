Status: running
Started: 2026-09-29T22:23:11Z
Budget: 20 items, until 2026-09-30T10:23:11Z
Digested-through: 0
Untracked-left: default.profraw macos/default.profraw scratchpad/ zig-out

## Progress
- Preflight 2026-09-29 (evening): main already merged; inbox empty; no vetoes or answers; B-067..B-075 promoted. Landed lanes B-054..B-064 still on disk (finish leaves them when untracked build output remains).

Lane: B-066
  Branch: autopilot-lane/B-066
  Base: 6c77ccb871b4f557a3ad8edf29810daf3893a6e4
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 81ba3075aff3fa53657ffea23fa81fe810b8c798
  Dispatched: 2026-09-29T22:24:16Z
  Call: Choose Agent… (the palette) stays on ⌘O, where B-057 put it; ⌘T is New Terminal alone — principle 1 / AUTONOMY shortcuts (D-125)
  Call: Quick Terminal keeps its menu item and no default key (upstream ships it unbound) — AUTONOMY UX/shortcuts
  Call: Start-screen tooltip reads LeoWindowTabbing.chooseAgentShortcut ("⌘O"), tied to the menu item by a test — AUTONOMY bug fixes/test infra
- B-066 runner: ready at 81ba3075a (1713/1713, lint clean; general full review; implementer/opus, 0 fix rounds). Base already had ⌘T on New Terminal alone; the clash left was the start screen's Choose Agent… tooltip still saying ⌘T. If Evan still sees ⌘T open the quick terminal, it's likely a toggle_quick_terminal keybind in his personal Ghostty config. Polish filed as B-076, B-077.
- B-066 landed (merge 4880318bb).
Finished 1: B-066 landed 4880318bb · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-066-1.png

Lane: B-067
  Branch: autopilot-lane/B-067
  Base: 00903ad066e09e9c9692b001fe9afca6f419a1fa
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: fa7a0d9b579554f70ae842d1c5f8fb58930b03b5
  Dispatched: 2026-09-29T23:12:02Z
  Call: The selected terminal row is also revealed when the filter clears or the list reappears, as Mail reveals its selection after a search — principle 1
  Call: Retitles and agent refreshes never scroll, and a row already on screen doesn't move — principle 2 calm
- B-067 runner: ready at fa7a0d9b5 (1715/1715, lint clean; general full; implementer/opus, 0 fix rounds). Harness couldn't reproduce B-057-8's partial reveal; only the live GUI run confirms the one-turn deferral. Polish filed as B-078; verify.md search-field tip folded into B-077.
- B-067 landed (merge 36c07da8b).
Finished 2: B-067 landed 36c07da8b · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-067-1.png

Lane: B-068
  Branch: autopilot-lane/B-068
  Base: caa947dd04da18fba08a8fb25b24645ea0074043
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-09-29T23:39:16Z
