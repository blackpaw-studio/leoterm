

## D-647 · 2026-10-29 · Global Hide Subagents flag with per-agent exceptions
Context: B-331 (runner call).
Chose: Global hidesSubagents flag plus per-agent exceptions; Hide Subagents clears the exceptions
Why: Calm; agent decides persistence
Commit: 0ce86a7d5
Veto: [ ]

## D-648 · 2026-10-29 · View ▸ Hide/Show Subagents on ⌥⌘S
Context: B-331 (runner call).
Chose: View ▸ Hide/Show Subagents on ⌥⌘S, no Ghostty or xib clash
Why: Keyboard-first; agent decides shortcut
Commit: 0ce86a7d5
Veto: [ ]

## D-649 · 2026-10-29 · Chevron on the name line; running count only when collapsed
Context: B-331 (runner call).
Chose: Chevron at trailing end of the name line; count only when collapsed and above 0, .running only
Why: Mac-native; never invents daemon state
Commit: 0ce86a7d5
Veto: [ ]

## D-650 · 2026-10-29 · Collapsing moves a hidden dispatch selection to its agent
Context: B-331 (runner call).
Chose: Collapse moves a hidden dispatch selection to its agent
Why: Mac-native
Commit: 0ce86a7d5
Veto: [ ]

## D-651 · 2026-10-29 · No ←/→ or ⌥-click disclosure handling
Context: B-331 (runner call).
Chose: No ←/→ or ⌥-click handling
Why: scope: not in the acceptance criteria
Commit: 0ce86a7d5
Veto: [ ]

## D-652 · 2026-10-29 · B-331 is Mac only; iOS is Out
Context: B-331 (runner call).
Chose: B-331 is Mac only; iOS is Out
Why: Mac+iOS parity rule
Commit: 0ce86a7d5
Veto: [ ]

## D-653 · 2026-11-05 · Minimal Zig export for binding-for-action lookup
Context: B-334 (runner call).
Chose: Keep the minimal Zig C export `ghostty_config_key_is_binding_for_action` instead of a Swift-only workaround
Why: AUTONOMY (Zig minimal) + VISION (menu keys reflect real keybinds)
Commit: 8b05121bb, 3d2b0d723, 79e5696fe, fe9df3739
Veto: [ ]

## D-654 · 2026-11-05 · Chained and leader bindings count as not this action
Context: B-334 (runner call).
Chose: Treat chained and leader bindings as "not this action" for Edit ▸ Copy/Paste
Why: VISION (no shortcut beats a wrong or shared one)
Commit: 8b05121bb, 3d2b0d723, 79e5696fe, fe9df3739
Veto: [ ]

## D-655 · 2026-11-05 · B-334 is Mac only
Context: B-334 (runner call).
Chose: Mac only: iOS has no Edit-menu key equivalents
Why: Mac/iOS parity rule
Commit: 8b05121bb, 3d2b0d723, 79e5696fe, fe9df3739
Veto: [ ]

## D-656 · 2026-11-05 · Managed web API via `leo web enable`, not Swift YAML edits
Context: B-339 (runner call).
Chose: Use the daemon's own `leo web enable --bind 127.0.0.1 --graceful` instead of editing YAML in Swift
Why: Everything through Leo; app-side fix lands without a daemon change
Commit: 736a17d24, ab3711f77, 59e4a3761, 2999f9341
Veto: [ ]

## D-657 · 2026-11-05 · Graceful restart at launch to turn on the web API
Context: B-339 (runner call).
Chose: Restart with a graceful drain at launch, after `restartIfUpdated()`; on drain timeout or failure show a notice
Why: Agent tools must reach the daemon
Commit: 736a17d24, ab3711f77, 59e4a3761, 2999f9341
Veto: [ ]

## D-658 · 2026-11-05 · Only touch an unambiguous managed leo.yaml
Context: B-339 (runner call).
Chose: Act only on a regular-file `~/.leo/leo.yaml` with no top-level `web` key and the managed marker; skip anything ambiguous
Why: Security: loopback only, never clobber user config
Commit: 736a17d24, ab3711f77, 59e4a3761, 2999f9341
Veto: [ ]

## D-659 · 2026-11-05 · B-339 is Mac only
Context: B-339 (runner call).
Chose: Mac only; the bundled daemon is a Mac app concern
Why: Mac/iOS parity rule
Commit: 736a17d24, ab3711f77, 59e4a3761, 2999f9341
Veto: [ ]

## D-660 · 2026-11-05 · Daemon default requested from the leo agent
Context: B-339 (runner call).
Chose: Ask the `leo` agent (non-blocking) to seed loopback `web` in the default config for managed installs
Why: AUTONOMY (messaging leo is agent-decides)
Commit: 736a17d24, ab3711f77, 59e4a3761, 2999f9341
Veto: [ ]

## D-661 · 2026-11-05 · session_missing worded in LeoKit for Mac and iOS
Context: B-340 (runner call).
Chose: Word `session_missing` in LeoKit (LeoAgentMover), so Mac and iOS both get it with no UI change
Why: Mac/iOS parity rule
Commit: d74ccc2bc, ba91e697d
Veto: [ ]

## D-662 · 2026-11-05 · Fresh-session move deferred to the daemon contract
Context: B-340 (runner call).
Chose: Defer "Move with a fresh session" until the daemon supports it; contract request sent to the leo agent
Why: Never invent a state the daemon didn't report
Commit: d74ccc2bc, ba91e697d
Veto: [ ]

## D-663 · 2026-11-05 · No Force offer for a stale-transcript move
Context: B-340 (runner call).
Chose: A stale-transcript move shows a plain message with no Force offer
Why: Calm, plain failures
Commit: d74ccc2bc, ba91e697d
Veto: [ ]

## D-664 · 2026-11-05 · Swift-side placement insert, validated by leo
Context: B-341 (runner call).
Chose: Swift inserts the missing placement line (validated via `leo config show` on a temp copy, atomic replace) since no leo CLI sets this key — deliberate exception to D-656 for this key only
Why: Swift under macos/ is agent-decides; never clobber user-authored config
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-665 · 2026-11-05 · Skip follower configs
Context: B-341 (runner call).
Chose: Skip configs with a top-level `follow:`, since an explicit placement may come from the lead
Why: An explicit user value wins
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-666 · 2026-11-05 · Placement migration fails quietly
Context: B-341 (runner call).
Chose: Migration failures only log, no notice; the old pane behaviour stays
Why: Sidebar is the navigation; calm by default
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-667 · 2026-11-05 · Placement block position
Context: B-341 (runner call).
Chose: With no `defaults` key, insert the block before the first top-level key
Why: Never clobber user-authored config
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-668 · 2026-11-05 · Skip ambiguous YAML
Context: B-341 (runner call).
Chose: Skip on anchors/aliases at a scanned level and on compact sequences
Why: Never clobber user-authored config
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-669 · 2026-11-05 · One restart per launch covers both
Context: B-341 (runner call).
Chose: Run after `restartIfUpdated()` and before `ensureWebAPI()`, no restart of its own (daemon reads leo.yaml per dispatch)
Why: D-657
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-670 · 2026-11-05 · B-341 is Mac only
Context: B-341 (runner call).
Chose: Mac only
Why: Mac/iOS parity rule (D-659)
Commit: d60cdfbcd, 1dd5672dc, 9380313e1
Veto: [ ]

## D-671 · 2026-11-05 · Chat image sizing shared in LeoKit, Mac and iOS
Context: B-343 (runner call).
Chose: Fix on both platforms; the sizing rule lives in LeoKit `LeoChatImageLayout`, each app keeps only its image view
Why: Mac/iOS parity rule
Commit: 56ccb4ab0, a82a2ec8e, 1422127bc
Veto: [ ]

## D-672 · 2026-11-05 · Tall chat images crop to a readable width
Context: B-343 (runner call).
Chose: Tall images crop aspect-fill (like iMessage) to a frame at least 200 pt wide; tapping opens the full image
Why: Bug fixes are agent-decides; Mac-native feel
Commit: 56ccb4ab0, a82a2ec8e, 1422127bc
Veto: [ ]

## D-673 · 2026-11-05 · Size chat images from original pixels
Context: B-343 (runner call).
Chose: iOS sizes chat images from the original file's pixel dimensions, not the thumbnail
Why: Bug fix
Commit: 56ccb4ab0, a82a2ec8e, 1422127bc
Veto: [ ]

## D-674 · 2026-11-05 · B-345 is Mac only
Context: B-345 (runner call).
Chose: Mac only (iOS has no sidebar rows)
Why: Mac/iOS parity rule
Commit: 2ba773d59
Veto: [ ]

## D-675 · 2026-11-05 · Chevron click exclusion capped at its own line
Context: B-345 (runner call).
Chose: The subagent chevron stays the disclosure control; its trailing click exclusion is capped at the name line so the rest of the row selects on one click
Why: D-651; the sidebar is the navigation
Commit: 2ba773d59
Veto: [ ]

## D-676 · 2026-11-05 · B-347 is iOS only
Context: B-347 (runner call).
Chose: iOS only: Mac has its own guard and shared LeoChatUnreadCounts already exempts the on-screen chat
Why: Mac/iOS parity rule; bug fixes are agent-decides
Commit: e64610753, 8a3393dab, db5c8be6b, 0413bde9c
Veto: [ ]

## D-677 · 2026-11-05 · Viewing = on screen and foregrounded
Context: B-347 (runner call).
Chose: "Viewing" means the chat is on screen and the app is foregrounded; a backgrounded badge is correct
Why: Calm, attention-driven
Commit: e64610753, 8a3393dab, db5c8be6b, 0413bde9c
Veto: [ ]

## D-678 · 2026-11-06 · B-346 is Mac only
Context: B-346 (runner call).
Chose: Mac only; iOS is Out and has its own share sheet
Why: Mac/iOS parity rule
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-679 · 2026-11-06 · Name collisions on attachment save
Context: B-346 (runner call).
Chose: A drop onto a taken name keeps both (reuses B-279); Download to… replaces only after the save panel confirms
Why: Agent-decides UX
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-680 · 2026-11-06 · Download to… menu placement
Context: B-346 (runner call).
Chose: "Download to…" sits under a divider in both the image and file-chip context menus
Why: Mac-native HIG
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-681 · 2026-11-06 · Save panel default folder
Context: B-346 (runner call).
Chose: The save panel leaves directoryURL unset (system remembers the last folder)
Why: Agent-decides UX
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-682 · 2026-11-06 · Attachment drag image
Context: B-346 (runner call).
Chose: The drag image is the scaled image, or the file icon for chips
Why: Agent-decides UX
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-683 · 2026-11-06 · AppKit drag bridge for chat attachments
Context: B-346 (runner call).
Chose: Drag via an AppKit overlay bridge modelled on SurfaceDragSource
Why: Mac-native; safer default, verified in the debug GUI
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-684 · 2026-11-06 · Attachment downloads pin the source machine
Context: B-346 (runner call).
Chose: Download from the machine fixed at drag/click start, reusing the chat download cache
Why: P3 Local = remote
Commit: 12a26cf2e, 8c86a5073, bcdaca1ea, 1391a1bda
Veto: [ ]

## D-685 · 2026-11-06 · B-342 is iOS only, gallery in LeoKit
Context: B-342 (runner call).
Chose: iOS only; the gallery helper lives in LeoKit so Mac can reuse it later
Why: Out; shared logic in LeoKit (AGENTS.md)
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-686 · 2026-11-06 · Photos-style chat image viewer
Context: B-342 (runner call).
Chose: Paging UIPageViewController with pinch/double-tap zoom, drag-down dismiss, close button and an "N of M" label
Why: Mobile-first, native UX
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-687 · 2026-11-06 · Viewer keeps the chat counted as viewing
Context: B-342 (runner call).
Chose: Present .overFullScreen so the chat stays "viewing" while the viewer is up
Why: D-676/D-677
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-688 · 2026-11-06 · Viewer shows uncropped originals
Context: B-342 (runner call).
Chose: The viewer shows the full uncropped original, aspect-fit
Why: D-671–D-673
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-689 · 2026-11-06 · Viewer pages images only
Context: B-342 (runner call).
Chose: "of N" counts only the message's images; non-image files keep Quick Look
Why: Agent-decides UX
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-690 · 2026-11-06 · Loading and failure inside the viewer
Context: B-342 (runner call).
Chose: Not-yet-loaded or failed images open the viewer with a spinner or a reason plus Try Again, replacing the "Couldn't Open" alert for images
Why: Calm; agent-decides UX
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-691 · 2026-11-06 · Viewer decode cap 4096 px
Context: B-342 (runner call).
Chose: Decode with ImageIO, longest side capped at 4096 px
Why: Memory bound
Commit: 2bab3994b, 4da8b4da9, 4949276a3
Veto: [ ]

## D-692 · 2026-11-06 · Answer to B-348: Mac test fixtures create NSWindow without…
Context: B-348 (Mac test fixtures create NSWindow without `isReleasedWhenClosed =…) blocked question
Chose: accept your recommendation (land it as is)
Why: the owner's answer
Commit:
Veto: n/a (owner)

## D-693 · 2026-11-06 · Answer to B-349: the update badge is weird now with the sidebar
Context: B-349 (the update badge is weird now with the sidebar) blocked question
Chose: retry
Why: the owner's answer
Commit:
Veto: n/a (owner)

## D-694 · 2026-11-06 · Answer to B-353: the time elapsed in the bar at the top is not updated…
Context: B-353 (the time elapsed in the bar at the top is not updated frequently…) blocked question
Chose: retry
Why: the owner's answer
Commit:
Veto: n/a (owner)

## D-695 · 2026-11-06 · Answer to B-354: this green is way too intense (Image #2)
Context: B-354 (this green is way too intense (Image #2)) blocked question
Chose: retry
Why: the owner's answer
Commit:
Veto: n/a (owner)

## D-696 · 2026-11-06 · B-349: Pill moves from a titlebar accessory to a native trailing toolbar item (.leoUpdate), left 
Chose: Pill moves from a titlebar accessory to a native trailing toolbar item (.leoUpdate), left of "⋯"; corner overlay stays off for agent windows — P1
Item: B-349 · the update badge is weird now with the sidebar
Commit: 486bf611d, 0df90da27
Veto: [ ]

## D-697 · 2026-11-06 · B-349: Narrow-width give-way order: subtitle, then pill, then title, then "⋯"; "Check for Updates
Chose: Narrow-width give-way order: subtitle, then pill, then title, then "⋯"; "Check for Updates…" stays in the app menu — P2
Item: B-349 · the update badge is weird now with the sidebar
Commit: 486bf611d, 0df90da27
Veto: [ ]

## D-698 · 2026-11-06 · B-349: Mac only; iOS has no Sparkle pill
Chose: Mac only; iOS has no Sparkle pill
Item: B-349 · the update badge is weird now with the sidebar
Commit: 486bf611d, 0df90da27
Veto: [ ]

## D-699 · 2026-11-06 · B-349: Pill width is measured (fittingSize + 10, 200 fallback) and re-measured on every state cha
Chose: Pill width is measured (fittingSize + 10, 200 fallback) and re-measured on every state change
Item: B-349 · the update badge is weird now with the sidebar
Commit: 486bf611d, 0df90da27
Veto: [ ]

## D-700 · 2026-11-06 · B-349: DEBUG-only LEO_UPDATE_FIXTURE env seam (compiled out of release) and LeoAgentToolbar.hides
Chose: DEBUG-only LEO_UPDATE_FIXTURE env seam (compiled out of release) and LeoAgentToolbar.hidesItemsInPlace test seam
Item: B-349 · the update badge is weird now with the sidebar
Commit: 486bf611d, 0df90da27
Veto: [ ]

## D-701 · 2026-11-06 · B-353: Mac only: iOS drives its own clock in AgentsViewController; the tick policy lives in LeoKi
Chose: Mac only: iOS drives its own clock in AgentsViewController; the tick policy lives in LeoKit if iOS wants it later — P1/P2
Item: B-353 · the time elapsed in the bar at the top is not updated frequently…
Commit: 07299f8c9
Veto: [ ]

## D-702 · 2026-11-06 · B-353: The Tasks popover and the sidebar row share the capsule's tick schedule (same durations, s
Chose: The Tasks popover and the sidebar row share the capsule's tick schedule (same durations, same staleness) — P2
Item: B-353 · the time elapsed in the bar at the top is not updated frequently…
Commit: 07299f8c9
Veto: [ ]

## D-703 · 2026-11-06 · B-353: New LeoTaskTick (LeoKit) ticks on a whole-second grid while any visible duration is under 
Chose: New LeoTaskTick (LeoKit) ticks on a whole-second grid while any visible duration is under a minute, else a coarse 15 s grid — P2 calm/steady status
Item: B-353 · the time elapsed in the bar at the top is not updated frequently…
Commit: 07299f8c9
Veto: [ ]

## D-704 · 2026-11-06 · B-354: Mac only (iOS has no task bar)
Chose: Mac only (iOS has no task bar) — P1
Item: B-354 · this green is way too intense (Image #2)
Commit: 7edc407da
Veto: [ ]

## D-705 · 2026-11-06 · B-354: Only the done bar's fill is softened; the checkmark glyph, popover and sidebar tints keep 
Chose: Only the done bar's fill is softened; the checkmark glyph, popover and sidebar tints keep full green — P2
Item: B-354 · this green is way too intense (Image #2)
Commit: 7edc407da
Veto: [ ]

## D-706 · 2026-11-06 · B-354: Done-bar opacity 0.55
Chose: Done-bar opacity 0.55 — P2
Item: B-354 · this green is way too intense (Image #2)
Commit: 7edc407da
Veto: [ ]

## D-707 · 2026-11-06 · B-348: Mac only (AppKit test fixtures); flag-line idiom (isReleasedWhenClosed = false per fixture
Chose: Mac only (AppKit test fixtures); flag-line idiom (isReleasedWhenClosed = false per fixture) rather than a makeTestWindow helper — test infrastructure is agent-decides
Item: B-348 · Mac test fixtures create NSWindow without `isReleasedWhenClosed =…
Commit: 5cfe63596, 1d03ef3ac, ac8ce9d31
Veto: [ ]

## D-708 · 2026-11-06 · B-348: Reused the shelved fix by cherry-pick, per the owner's answer (D-692)
Chose: Reused the shelved fix by cherry-pick, per the owner's answer (D-692)
Item: B-348 · Mac test fixtures create NSWindow without `isReleasedWhenClosed =…
Commit: 5cfe63596, 1d03ef3ac, ac8ce9d31
Veto: [ ]

## D-709 · 2026-11-06 · B-355: Fix the app, not just the tests: each image paste gets its own leo-paste-<uuid>/ temp dire
Chose: Fix the app, not just the tests: each image paste gets its own leo-paste-<uuid>/ temp directory; temp base injectable (LeoTerminalFileDropDependencies.temporaryDirectory); remote scratch name unchanged — P3
Item: B-355 · LeoRuntimeFileDropTests fails and aborts the Mac test host
Commit: 513ac9c8d, 50fc4c72c
Veto: [ ]

## D-710 · 2026-11-06 · B-355: Suite hardening: try #require on first insert, throwing makeAccess, 10 s ceiling on the tw
Chose: Suite hardening: try #require on first insert, throwing makeAccess, 10 s ceiling on the two SFTP-backed waits, @MainActor State — test infrastructure
Item: B-355 · LeoRuntimeFileDropTests fails and aborts the Mac test host
Commit: 513ac9c8d, 50fc4c72c
Veto: [ ]

## D-711 · 2026-11-06 · B-355: Mac only: image paste is Mac-only, LeoKit untouched
Chose: Mac only: image paste is Mac-only, LeoKit untouched
Item: B-355 · LeoRuntimeFileDropTests fails and aborts the Mac test host
Commit: 513ac9c8d, 50fc4c72c
Veto: [ ]

## D-712 · 2026-11-08 · B-358: Mac only, since iOS has no split zoom — P1
Chose: Mac only, since iOS has no split zoom — P1
Item: B-358 · Reset-zoom titlebar accessory likely sits low in the unified toolbar
Commit: 2596f13ca
Veto: [ ]

## D-713 · 2026-11-08 · B-358: Native bordered image toolbar item `.leoResetZoom` (before `.leoUpdate` and `.leoMore`) in
Chose: Native bordered image toolbar item `.leoResetZoom` (before `.leoUpdate` and `.leoMore`) in place of the `.right` titlebar accessory; other window styles keep the accessory — P1
Item: B-358 · Reset-zoom titlebar accessory likely sits low in the unified toolbar
Commit: 2596f13ca
Veto: [ ]

## D-714 · 2026-11-08 · B-358: Item uses visibilityPriority .high and never gives way to the activity capsule, since it i
Chose: Item uses visibilityPriority .high and never gives way to the activity capsule, since it is an action — P2
Item: B-358 · Reset-zoom titlebar accessory likely sits low in the unified toolbar
Commit: 2596f13ca
Veto: [ ]

## D-715 · 2026-11-08 · B-363: Scope the task panel to the open thread only, not to the list (iPad regular width hides ot
Chose: Scope the task panel to the open thread only, not to the list (iPad regular width hides other agents' tasks while a thread is open) — P2 calm, attention-driven
Item: B-363 · On iOS, tasks from one agent show in the chat of other agents. A task…
Commit: 71b459eda
Veto: [ ]

## D-716 · 2026-11-08 · B-363: iOS only; the Mac task capsule is already per-agent — repo Mac/iOS rule
Chose: iOS only; the Mac task capsule is already per-agent — repo Mac/iOS rule
Item: B-363 · On iOS, tasks from one agent show in the chat of other agents. A task…
Commit: 71b459eda
Veto: [ ]

## D-717 · 2026-11-08 · B-364: Mac only — the managed daemon exists only in the macOS app, and iOS had no such migration 
Chose: Mac only — the managed daemon exists only in the macOS app, and iOS had no such migration (matches D-670)
Item: B-364 · (cleanup, follow-up to B-341) Bundled leo is now 0.76.0 (PR #335,…
Commit: c2be26f86
Veto: [ ]

## D-718 · 2026-11-08 · B-364: No `PUT /config/defaults` fallback — leo 0.76.0 defaults placement to window, so the app h
Chose: No `PUT /config/defaults` fallback — leo 0.76.0 defaults placement to window, so the app has nothing to set (P2/P4)
Item: B-364 · (cleanup, follow-up to B-341) Bundled leo is now 0.76.0 (PR #335,…
Commit: c2be26f86
Veto: [ ]

## D-719 · 2026-11-08 · B-364: Moved the post-launch sequence into `LeoManagedStartup.runPostLaunchSteps()` so it can be 
Chose: Moved the post-launch sequence into `LeoManagedStartup.runPostLaunchSteps()` so it can be tested, with no behaviour change — test detail
Item: B-364 · (cleanup, follow-up to B-341) Bundled leo is now 0.76.0 (PR #335,…
Commit: c2be26f86
Veto: [ ]

## D-720 · 2026-11-08 · B-365: "Leo Help" retitled along with the three items in the screenshot — P1 (first-party Mac fee
Chose: "Leo Help" retitled along with the three items in the screenshot — P1 (first-party Mac feel)
Item: B-365 · some menu items still reference Ghostty
Commit: f4ae9a545
Veto: [ ]

## D-721 · 2026-11-08 · B-365: Mac only: the menu bar has no iOS equivalent — repo rule
Chose: Mac only: the menu bar has no iOS equivalent — repo rule
Item: B-365 · some menu items still reference Ghostty
Commit: f4ae9a545
Veto: [ ]

## D-722 · 2026-11-08 · B-365: Built the xcframework inside the lane because shared/ predates the B-334 symbol; src/ unto
Chose: Built the xcframework inside the lane because shared/ predates the B-334 symbol; src/ untouched — verify.md
Item: B-365 · some menu items still reference Ghostty
Commit: f4ae9a545
Veto: [ ]

## D-723 · 2026-11-08 · B-369: Mac only: iOS chat thread has no start prompt, so stopped chats already open there — repo 
Chose: Mac only: iOS chat thread has no start prompt, so stopped chats already open there — repo Mac/iOS rule
Item: B-369 · i should be able to view the chat of a stopped agent without the start…
Commit: 168f074d3, aa255f832
Veto: [ ]

## D-724 · 2026-11-08 · B-369: Plain click or Return on a non-running agent shows its chat; no Start sheet, nothing auto-
Chose: Plain click or Return on a non-running agent shows its chat; no Start sheet, nothing auto-starts — P2/P5
Item: B-369 · i should be able to view the chat of a stopped agent without the start…
Commit: 168f074d3, aa255f832
Veto: [ ]

## D-725 · 2026-11-08 · B-369: Slim "<name> isn't running." bar with a Start button above the chat composer ("is starting
Chose: Slim "<name> isn't running." bar with a Start button above the chat composer ("is starting…" while starting) — P2/P5
Item: B-369 · i should be able to view the chat of a stopped agent without the start…
Commit: 168f074d3, aa255f832
Veto: [ ]

## D-726 · 2026-11-08 · B-369: Cmd-click and opt-double-click (new-window terminal) keep the Start sheet, since they need
Chose: Cmd-click and opt-double-click (new-window terminal) keep the Start sheet, since they need a running agent — P1
Item: B-369 · i should be able to view the chat of a stopped agent without the start…
Commit: 168f074d3, aa255f832
Veto: [ ]

## D-727 · 2026-11-08 · B-366: Docs opens the leoterm README (no Leo docs URL exists in the repo; none invented) — P1
Chose: Docs opens the leoterm README (no Leo docs URL exists in the repo; none invented) — P1
Item: B-366 · buttons in the about window link to ghostty repo and docs instead of…
Commit: 3d87c55b0
Veto: [ ]

## D-728 · 2026-11-08 · B-366: Version link opens the leoterm release tag leo-v<version> — P1
Chose: Version link opens the leoterm release tag leo-v<version> — P1
Item: B-366 · buttons in the about window link to ghostty repo and docs instead of…
Commit: 3d87c55b0
Veto: [ ]

## D-729 · 2026-11-08 · B-366: Commit link opens leoterm commits/<sha> — P1
Chose: Commit link opens leoterm commits/<sha> — P1
Item: B-366 · buttons in the about window link to ghostty repo and docs instead of…
Commit: 3d87c55b0
Veto: [ ]

## D-730 · 2026-11-08 · B-366: Mac only; the About window exists only on Mac — repo rule
Chose: Mac only; the About window exists only on Mac — repo rule
Item: B-366 · buttons in the about window link to ghostty repo and docs instead of…
Commit: 3d87c55b0
Veto: [ ]

## D-731 · 2026-11-09 · B-376: Mac only (agent browser is a Mac WKWebView pane) — platform rule
Chose: Mac only (agent browser is a Mac WKWebView pane) — platform rule
Item: B-376 · agent browser can't load hyatt.com (every page blank with an empty…
Commit: b7ce634f9, e8fde9370
Veto: [ ]

## D-732 · 2026-11-09 · B-376: Kept and fixed the page-world console hook (describe only own data properties) instead of removing it or moving it to the LeoAgent world, so browser_console keeps working — P4, bug fix
Chose: Kept and fixed the page-world console hook (describe only own data properties) instead of removing it or moving it to the LeoAgent world, so browser_console keeps working — P4, bug fix
Item: B-376 · agent browser can't load hyatt.com (every page blank with an empty…
Commit: b7ce634f9, e8fde9370
Veto: [ ]

## D-733 · 2026-11-09 · B-376: Left applicationNameForUserAgent alone (UA hypothesis tested irrelevant) — agent-decides
Chose: Left applicationNameForUserAgent alone (UA hypothesis tested irrelevant) — agent-decides
Item: B-376 · agent browser can't load hyatt.com (every page blank with an empty…
Commit: b7ce634f9, e8fde9370
Veto: [ ]

## D-734 · 2026-11-09 · B-377: browser_eval auto-returns a bare expression (with a CSP-safe path) instead of rewording the tool description, which already says "expression or statements" — P4
Chose: browser_eval auto-returns a bare expression (with a CSP-safe path) instead of rewording the tool description, which already says "expression or statements" — P4
Item: B-377 · browser_eval (LeoWKBrowserPage.swift:180) runs its input as a function…
Commit: 7119ca3dd, 025024ab5
Veto: [ ]

## D-735 · 2026-11-09 · B-377: Mac only (agent browser is a Mac WKWebView pane) — platform rule
Chose: Mac only (agent browser is a Mac WKWebView pane) — platform rule
Item: B-377 · browser_eval (LeoWKBrowserPage.swift:180) runs its input as a function…
Commit: 7119ca3dd, 025024ab5
Veto: [ ]

## D-736 · 2026-11-09 · B-368: Mac only (macos/ test code, no iOS counterpart) — AGENTS.md parity rule
Chose: Mac only (macos/ test code, no iOS counterpart) — AGENTS.md parity rule
Item: B-368 · theProbeSurvivesTheSidebarResizingAfterItReported is flaky
Commit: f2c68564b
Veto: [ ]

## D-737 · 2026-11-09 · B-368: Test-helper flake fix — AUTONOMY "agent decides"
Chose: Test-helper flake fix — AUTONOMY "agent decides"
Item: B-368 · theProbeSurvivesTheSidebarResizingAfterItReported is flaky
Commit: f2c68564b
Veto: [ ]

## D-738 · 2026-11-09 · B-378: Fix the retained-view bug in product code, not just the test's wait — AUTONOMY "bug fixes, flake fixes"
Chose: Fix the retained-view bug in product code, not just the test's wait — AUTONOMY "bug fixes, flake fixes"
Item: B-378 · closingTheWindowFreesItsHiddenShells is flaky — failed in the…
Commit: e0daf5ecb
Veto: [ ]

## D-739 · 2026-11-09 · B-378: Mac only (Ghostty surface code in macos/, iOS has no equivalent) — AGENTS.md parity rule
Chose: Mac only (Ghostty surface code in macos/, iOS has no equivalent) — AGENTS.md parity rule
Item: B-378 · closingTheWindowFreesItsHiddenShells is flaky — failed in the…
Commit: e0daf5ecb
Veto: [ ]

## D-740 · 2026-11-09 · B-379: Flake and test-infrastructure fix, no product change — AUTONOMY "agent decides"
Chose: Flake and test-infrastructure fix, no product change — AUTONOMY "agent decides"
Item: B-379 · cancellationClosesConnection is flaky — failed the leo-v0.33.1 release…
Commit: 2f6080e9d
Veto: [ ]

## D-741 · 2026-11-09 · B-379: Mac only — test infra under macos/Tests, nothing in LeoKit or iOS
Chose: Mac only — test infra under macos/Tests, nothing in LeoKit or iOS
Item: B-379 · cancellationClosesConnection is flaky — failed the leo-v0.33.1 release…
Commit: 2f6080e9d
Veto: [ ]

## D-742 · 2026-11-09 · B-379: The 400 ms "cancel returns quickly" assertion stays as it was — it wasn't the reported failure
Chose: The 400 ms "cancel returns quickly" assertion stays as it was — it wasn't the reported failure
Item: B-379 · cancellationClosesConnection is flaky — failed the leo-v0.33.1 release…
Commit: 2f6080e9d
Veto: [ ]

## D-743 · 2026-11-10 · B-381: Mac only: iOS is Out and the filter sits in the Mac presentation, not LeoKit — AGENTS.md platform rule
Chose: Mac only: iOS is Out and the filter sits in the Mac presentation, not LeoKit — AGENTS.md platform rule
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-744 · 2026-11-10 · B-381: Indeterminate task falls back to the row's trailing time, per LeoKit's nil contract — VISION 2 (never invent a state)
Chose: Indeterminate task falls back to the row's trailing time, per LeoKit's nil contract — VISION 2 (never invent a state)
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-745 · 2026-11-10 · B-381: Line-2 task title opens Tasks on every row whose line 2 shows a task; hit area is the text only — VISION 1, accept's own example
Chose: Line-2 task title opens Tasks on every row whose line 2 shows a task; hit area is the text only — VISION 1, accept's own example
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-746 · 2026-11-10 · B-381: Removed the dead indeterminate spinner code from LeoTaskIndicatorView — AUTONOMY agent decides
Chose: Removed the dead indeterminate spinner code from LeoTaskIndicatorView — AUTONOMY agent decides
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-747 · 2026-11-10 · B-381: Rebuilt the GhosttyKit xcframework inside the lane because the shared one was stale (build output, untracked) — AUTONOMY agent decides
Chose: Rebuilt the GhosttyKit xcframework inside the lane because the shared one was stale (build output, untracked) — AUTONOMY agent decides
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-748 · 2026-11-10 · B-381: Left the toolbar capsule's spinner alone — outside the row, not in the accept
Chose: Left the toolbar capsule's spinner alone — outside the row, not in the accept
Item: B-381 · Working arrows always spin; static determinate pie; hide indeterminate…
Commit: 87e56dcee, 0654c9b32
Veto: [ ]

## D-749 · 2026-11-10 · B-387: Merged PR #356 head via --no-ff merge, no cherry-pick — brief principle and B-364 precedent
Chose: Merged PR #356 head via --no-ff merge, no cherry-pick — brief principle and B-364 precedent
Item: B-387 · Land bundled leo daemon bump to 0.81.0 (PR #356)
Commit: 57d20ed25
Veto: [ ]

## D-750 · 2026-11-10 · B-387: Mac only — bundled daemon is a Mac app concern
Chose: Mac only — bundled daemon is a Mac app concern
Item: B-387 · Land bundled leo daemon bump to 0.81.0 (PR #356)
Commit: 57d20ed25
Veto: [ ]

## D-751 · 2026-11-10 · B-389: Fork PRs named bump/leo-* are never closed — AUTONOMY: CI config agent-decides; non-bump PR never touched
Chose: Fork PRs named bump/leo-* are never closed — AUTONOMY: CI config agent-decides; non-bump PR never touched
Item: B-389 · Bundled-leo bump workflow closes the bump PRs it supersedes
Commit: 689c966a9
Veto: [ ]

## D-752 · 2026-11-10 · B-389: Closing never deletes a branch — criteria: "deletes nothing else"
Chose: Closing never deletes a branch — criteria: "deletes nothing else"
Item: B-389 · Bundled-leo bump workflow closes the bump PRs it supersedes
Commit: 689c966a9
Veto: [ ]

## D-753 · 2026-11-10 · B-389: Bump branches without strict X.Y.Z are skipped — conservative; no guessing at versions
Chose: Bump branches without strict X.Y.Z are skipped — conservative; no guessing at versions
Item: B-389 · Bundled-leo bump workflow closes the bump PRs it supersedes
Commit: 689c966a9
Veto: [ ]

## D-754 · 2026-11-10 · B-389: Closing step also runs when the workflow updates an existing PR — idempotent
Chose: Closing step also runs when the workflow updates an existing PR — idempotent
Item: B-389 · Bundled-leo bump workflow closes the bump PRs it supersedes
Commit: 689c966a9
Veto: [ ]

## D-755 · 2026-11-10 · B-389: Platform: CI only, neither Mac nor iOS
Chose: Platform: CI only, neither Mac nor iOS
Item: B-389 · Bundled-leo bump workflow closes the bump PRs it supersedes
Commit: 689c966a9
Veto: [ ]

## D-756 · 2026-11-10 · B-385: Mac only: the agent browser is a Mac WKWebView pane — VISION 1
Chose: Mac only: the agent browser is a Mac WKWebView pane — VISION 1
Item: B-385 · Agent browser blocked by Chase as an unsupported browser — the sign-in…
Commit: 181560144
Veto: [ ]

## D-757 · 2026-11-10 · B-385: Not contradicting D-733: it left the UA alone because it was irrelevant to the hyatt.com blank page (B-376); Chase gating on the Safari version is new evidence — VISION 4
Chose: Not contradicting D-733: it left the UA alone because it was irrelevant to the hyatt.com blank page (B-376); Chase gating on the Safari version is new evidence — VISION 4
Item: B-385 · Agent browser blocked by Chase as an unsupported browser — the sign-in…
Commit: 181560144
Veto: [ ]

## D-758 · 2026-11-10 · B-385: Claim the installed Safari's major.minor (fallback Version/17.0), not a hardcoded constant — VISION 4
Chose: Claim the installed Safari's major.minor (fallback Version/17.0), not a hardcoded constant — VISION 4
Item: B-385 · Agent browser blocked by Chase as an unsupported browser — the sign-in…
Commit: 181560144
Veto: [ ]

## D-759 · 2026-11-10 · B-386: new `browser_user_agent` tool for existing tabs, plus an optional `user_agent` on `browser_tab_new` — explicit semantics, navigate unchanged (VISION 4)
Chose: new `browser_user_agent` tool for existing tabs, plus an optional `user_agent` on `browser_tab_new` — explicit semantics, navigate unchanged (VISION 4)
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-760 · 2026-11-10 · B-386: empty string or whitespace-only clears; a missing or null `user_agent` fails `invalid_args` — a bare call can't wipe an override
Chose: empty string or whitespace-only clears; a missing or null `user_agent` fails `invalid_args` — a bare call can't wipe an override
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-761 · 2026-11-10 · B-386: values must be printable ASCII 0x20–0x7E, max 1024 characters — blocks header injection
Chose: values must be printable ASCII 0x20–0x7E, max 1024 characters — blocks header injection
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-762 · 2026-11-10 · B-386: both actions fail with `user_has_control` while the user drives, like `browser_tab_new`
Chose: both actions fail with `user_has_control` while the user drives, like `browser_tab_new`
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-763 · 2026-11-10 · B-386: popups inherit the opener's override (only when non-empty) — UA-gated login popups keep working (VISION 4)
Chose: popups inherit the opener's override (only when non-empty) — UA-gated login popups keep working (VISION 4)
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-764 · 2026-11-10 · B-386: no pane UI indicator and no `user_agent` field in `browser_tabs` — small scope cut
Chose: no pane UI indicator and no `user_agent` field in `browser_tabs` — small scope cut
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-765 · 2026-11-10 · B-386: the schemas live in this repo, so no daemon change and no `~/.leo/agents/leo` edit — Mac only per D-756 (iOS is Out)
Chose: the schemas live in this repo, so no daemon change and no `~/.leo/agents/leo` edit — Mac only per D-756 (iOS is Out)
Item: B-386 · Agents can override the agent browser's user agent per tab
Commit: 3010fcffe 5967f05c0
Veto: [ ]

## D-766 · 2026-11-10 · B-390: Move the Tasks-popover click from the row's line-2 status text to the activity (spinning) icon; supersedes D-745 per the owner's B-390 report — VISION 1, owner request
Chose: Move the Tasks-popover click from the row's line-2 status text to the activity (spinning) icon; supersedes D-745 per the owner's B-390 report — VISION 1, owner request
Item: B-390 · i dont like that the status text subtitle on the sidebar rows taps to…
Commit:
Veto: [ ]
