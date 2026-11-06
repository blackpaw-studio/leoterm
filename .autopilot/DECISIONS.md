

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
