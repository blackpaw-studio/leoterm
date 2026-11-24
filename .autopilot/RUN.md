Status: finished
Started: 2026-11-24T00:56:31Z
Budget: 20 items, until 2026-11-24T12:56:31Z
Digested-through: 0
Filed: 3/3 bugs, 1/5 ideas
Self-filed: B-324 → B-442 bug — Mac composer on a moved agent still offers Start and shows Idle
Self-filed: B-441 → B-444 bug — Escape doesn't close the full-window image viewer while caps lock is on
Self-filed: B-441 → B-445 bug — Right-click on a chat image misses after a send (reply shifts scroll)
Self-filed: B-441 → B-446 idea — Menu items for the chat image viewer's Open/Exit Full Window and Close
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

Lane: B-324
  Branch: autopilot-lane/B-324
  Base: 785cf8d787f0446d2fa3200b902d16160ec883d9
  Tier: full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 7880c2ee4501a72c279836a7cb6589d2b0385c7a
  Dispatched: 2026-11-24T00:59:01Z
  Call: A moved row opened in a new window (⌘-click, ⌥-double-click) shows its chat, like a plain click, not a Start sheet — VISION 2, 6
  Call: The chat bar on a moved row reads "<name> moved to <host>." with no Start button — VISION 2
  Call: The moved-row guard in go(to:) comes before the status check, so it covers every status — VISION 2
  Tokens: 21.2M in (20.7M cache read), ≥74.5k out, 189 requests

Lane: B-437
  Branch: autopilot-lane/B-437
  Base: 785cf8d787f0446d2fa3200b902d16160ec883d9
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 6b1e9792a69e1a2edc7af425f3bc49dc5a753427
  Dispatched: 2026-11-24T00:59:01Z
  Tokens: 4.27M in (4.04M cache read), ≥19.4k out, 53 requests

  Call: iOS only (the Mac app has no notch or side safe area) — Mac/iOS parity rule; consistent with D-989

Lane: B-441
  Branch: autopilot-lane/B-441
  Base: 06b47fbd7a14f3063ed1aa7d8ff97499b0e56904
  Tier: light→full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 55d74e838f399798c9e885dd8e7b678edd526e35
  Dispatched: 2026-11-24T01:16:36Z
  Call: Arrows and header buttons step only in the full-window viewer; the pane viewer keeps its arrows — principle 1 / principle 6
  Call: Stepping stops at either end, no wrap (as in Preview) — principle 1
  Call: View ▸ Previous Image / Next Image added in this item, enabled exactly where the arrow keys step — principle 1
  Call: Mac only: iOS already pages a message's images (ChatImagePageController), so nothing moves to LeoKit — AGENTS.md parity rule
  Tokens: 25M in (24.4M cache read), ≥113k out, 228 requests

Lane: B-443
  Branch: autopilot-lane/B-443
  Base: c396b9d07cf69bbdc580382d310c9a5c9fc582a0
  Tier: light→full
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: a51b4b40ec3b3c9ba748ae560ad5ab10afea14a6
  Dispatched: 2026-11-24T01:49:51Z
  Call: Mac only; iOS has no plugin settings or updater consumer, and the updater logic is already in LeoKit — Mac/iOS parity rule
  Call: Each git plugin row shows "Follows “<ref>”" and a "Change…" link, not shown for bundled or dev plugins — Keyboard-first, Mac-native
  Call: A stored `HEAD` reads as "the default branch", and an empty field switches back to it — Calm, attention-driven
  Call: Reuses the existing approval sheet — Local = remote; Everything through Leo
  Call: A declined ref change shows no message, same as a declined install — Never invent a state
  Call: A same-commit ref switch refreshes the row without restarting the plugin — Never invent a state
  Call: "Change…" stays an inline row button with no menu item or shortcut, like Uninstall — Keyboard-first, Mac-native
  Tokens: 22.4M in (21.8M cache read), ≥78.2k out, 196 requests

Lane: B-439
  Branch: autopilot-lane/B-439
  Base: 095fd564e1c3abfbce82c49343dc0a916af638c8
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-24T02:42:35Z

Lane: B-438
  Branch: autopilot-lane/B-438
  Base: 4011ab001ea209a57f368aea2219ee889c0207fa
  Tier: full
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none
  Dispatched: 2026-11-24T03:50:29Z

Finished 1: B-437 landed edf4408a04be9f93246dcc6a9d797b1b03e1f0a1 · not visually verified
Finished 2: B-324 landed b127fba37f1e77389dbefb41208c828647e377e5 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-324-2.png
Inbox applied: B-443
Finished 3: B-441 landed 45a6e33e9dc43c681e3894e5fc647137ab398441 · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-441-1.png
Progress: B-439 built before B-440 (B-440 drag-to-dock depends on B-439 docking)
Finished 4: B-443 landed 0809800ef115cc078abbf2ee18312a186bca7331 · not visually verified
Progress: early stop 2026-11-24T05:30Z — disk full (ENOSPC) on Dionysus; leo daemon dropped; B-438 and B-439 runners reported Error; nested implementers cancelled; both lanes clean with commits, left building for next run; verify lock (B-439) released; orphaned B-439 test host stopped
