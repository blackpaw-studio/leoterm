Status: running
Started: 2026-10-29T02:17:35Z
Budget: 20 items, until 2026-10-29T14:17:35Z
Digested-through: 0
Filed: 1/3 bugs, 0/5 ideas
Self-filed: B-325 → B-334 bug — Paste/Copy menu gets ⌘V/⌘C whenever the key is bound to anything
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
  Tokens: 60.9M in (60.1M cache read), ≥192k out, 352 requests
  Dispatched: 2026-10-06T23:01:21Z

Lane: B-325
  Branch: autopilot-lane/B-325
  Base: 791b934ff3bf2fa421c405e771b29651301b3a77
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: d778bfce1f9ba3c167d40b82bea1eefd5b5d6063
  Dispatched: 2026-10-29T02:20:31Z
  Call: Mac only; iOS has no menu bar and uses UIKit's own paste — Keyboard-first/Mac-native
  Call: app-wide, like D-592 — Keyboard-first/Mac-native
  Tokens: 6.18M in (5.91M cache read), ≥25.3k out, 75 requests

Lane: B-328
  Branch: autopilot-lane/B-328
  Base: cf19af992d2a325020bac1d822a17cb0e1402082
  Tier: light
  State: landed
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: 8e11cce2a1c69039b2c040c8bd66bf153aebc553
  Dispatched: 2026-10-29T02:56:32Z
  Call: Close Leo sheets through their window (LeoSheetDismiss + .leoSheetClose(in: window)), falling back to \.dismiss under SwiftUI .sheet — Keyboard-first, Mac-native
  Call: B-328 sheet-close fix is Mac only (iOS doesn't use presentLeoSheet) — Mac+iOS parity rule
  Call: LeoSpawnSheetHostingController becomes NSHostingController<AnyView> so the close value can be injected — implementation approach
  Tokens: 13.2M in (12.8M cache read), ≥49.6k out, 140 requests

Lane: B-329
  Branch: autopilot-lane/B-329
  Base: defe83c4070d4c4f4de52c9960dbb8cd240b675c
  Tier: light
  State: building
  Fixes: 0
  Wip: none
  Reverifies: 0
  Reviewed-tip: none

Progress:
Runner B-325: leo dispatch d-b58f99910543; wake timer bf18g6lzs
Finished 1: B-325 landed e80b304df · shot /Users/evan/.leo/agents/leoterm/.git/autopilot/worktree/.autopilot/shots/B-325-0.png
B-325 landed e80b304df (≈$2.15 est.)
Runner B-328: leo dispatch d-021a185b277e
Finished 2: B-328 landed 7a99dacfa · shot screen capture, not attached
B-328 landed 7a99dacfa (≈$3.44 est.); note: committed test never seen failing (probe with \.dismiss did fail); Copy sheet could move to LeoSheetDismiss once B-324 lands
