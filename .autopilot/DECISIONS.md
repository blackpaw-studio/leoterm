

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
