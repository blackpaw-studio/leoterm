Status: running
Started: 2026-09-29T22:23:11Z
Budget: 20 items, until 2026-09-30T10:23:11Z
Digested-through: 5
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
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7f4db8ef29323576e4eb3f23305b764170a5ac84
  Dispatched: 2026-09-29T23:39:16Z
  Call: Numbered suffix, not a tty name: the first row stays plain ("~", "~ (2)", "~ (3)"), like Finder's "untitled folder 2" — principle 1, AUTONOMY UX/copy
  Call: Labels are recomputed from row order and titles: a retitle or close can renumber later same-titled rows, but rows never move and a new shell never relabels an older one — AUTONOMY, D-130
  Call: The suffix is secondary-coloured with monospaced digits and never truncates — AUTONOMY polish
- B-068 runner: ready at 7f4db8ef2 (1724/1724; general full; implementer/opus, 0 fix rounds). Two integration tests moved to a /bin/cat stand-in (prompt retitle race). Polish filed as B-079; B-072 noted.
- B-068 landed (merge 2f94a8036).
Finished 3: B-068 landed 2f94a8036 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-068-1.png

Lane: B-069
  Branch: autopilot-lane/B-069
  Base: 84fb9f4ff009fbb18e8b1855a744587332dacc01
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: f12743766d043014cada1ae123bec4f572bc79aa
  Dispatched: 2026-09-30T00:26:01Z
  Call: The start-screen New Terminal button sends ⌘T's newTab: to the clicked window's controller (nil-target fallback), so the row lands in that window — AUTONOMY UX
  Call: The button is plain bordered; Choose Agent… stays the one prominent button — AUTONOMY layout/polish
  Call: The button is always enabled, even while disconnected (a shell doesn't need the daemon) — AUTONOMY UX
  Call: Its title and "⌘T" tooltip come from LeoWindowTabbing constants tied to the ⌘T menu item by a test (D-128 pattern) — principle 1, AUTONOMY copy
- B-069 runner: ready at f12743766 (1727/1727, lint clean; general full; implementer/opus, 0 fix rounds). Polish filed as B-080.
- B-069 landed (merge 8976cf27b).
Finished 4: B-069 landed 8976cf27b · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-069-1.png

Lane: B-070
  Branch: autopilot-lane/B-070
  Base: c816b50f24896c83e5a4f85ada009f159bfa25ee
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 6456f99877bd641191f1d9894d606d46e145d114
  Dispatched: 2026-09-30T00:43:21Z
  Call: A title set with Change Window Title… survives the start screen; it names the window, not the shell — principle 1, D-107
  Call: The closed shell's folder proxy icon is cleared on the start screen, matching a fresh window — principle 2 never invent a state
- B-070 runner: ready at 6456f9987 (1730/1730, lint clean; general full; implementer/opus, 0 fix rounds). Root cause: leoShowStartScreen → focusedSurfaceDidChange(nil) set a bare "👻"; the old test only asserted the title wasn't the shell's. Polish filed as B-081.
- B-070 landed (merge d58cdd886).
Finished 5: B-070 landed d58cdd886 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-070-1.png
